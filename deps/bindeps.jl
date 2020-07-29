# discovering binary CUDA dependencies

using Pkg, Pkg.Artifacts
import Libdl


## global state

const __toolkit_origin = Ref{Symbol}()

"""
    toolkit_origin()

Returns the origin of the CUDA toolkit in use (either :artifact, or :local).
"""
toolkit_origin() = @after_init(__toolkit_origin[])

const __toolkit_version = Ref{VersionNumber}()

"""
    toolkit_version()

Returns the version of the CUDA toolkit in use.
"""
toolkit_version() = @after_init(__toolkit_version[])

"""
    toolkit_release()

Returns the CUDA release part of the version as returned by [`version`](@ref).
"""
toolkit_release() = @after_init(VersionNumber(__toolkit_version[].major, __toolkit_version[].minor))

const __nvdisasm = Ref{String}()
const __libdevice = Ref{String}()
const __libcudadevrt = Ref{String}()
const __libcupti = Ref{Union{Nothing,String}}()
const __libnvtx = Ref{Union{Nothing,String}}()
const __libcublas = Ref{String}()
const __libcusparse = Ref{String}()
const __libcusolver = Ref{String}()
const __libcufft = Ref{String}()
const __libcurand = Ref{String}()
const __libcudnn = Ref{Union{Nothing,String}}(nothing)
const __libcutensor = Ref{Union{Nothing,String}}(nothing)

nvdisasm() = @after_init(__nvdisasm[])
libdevice() = @after_init(__libdevice[])
libcudadevrt() = @after_init(__libcudadevrt[])
function libcupti()
    @after_init begin
        @assert has_cupti() "This functionality is unavailable as CUPTI is missing."
        __libcupti[]
    end
end
function libnvtx()
    @after_init begin
        @assert has_nvtx() "This functionality is unavailable as NVTX is missing."
        __libnvtx[]
    end
end

export has_cupti, has_nvtx
has_cupti() = @after_init(__libcupti[]) !== nothing
has_nvtx() = @after_init(__libnvtx[]) !== nothing

libcublas() = @after_init(__libcublas[])
libcusparse() = @after_init(__libcusparse[])
libcusolver() = @after_init(__libcusolver[])
libcufft() = @after_init(__libcufft[])
libcurand() = @after_init(__libcurand[])
function libcudnn()
    @after_init begin
        @assert has_cudnn() "This functionality is unavailabe as CUDNN is missing."
        __libcudnn[]
    end
end
function libcutensor()
    @after_init begin
        @assert has_cutensor() "This functionality is unavailabe as CUTENSOR is missing."
        __libcutensor[]
    end
end

export has_cudnn, has_cutensor
has_cudnn() = @after_init(__libcudnn[]) !== nothing
has_cutensor() = @after_init(__libcutensor[]) !== nothing


## discovery

# utilities to look up stuff in the artifact (at known locations)
artifact_binary(artifact_dir, name) = joinpath(artifact_dir, "bin", Sys.iswindows() ? "$name.exe" : name)
artifact_static_library(artifact_dir, name) = joinpath(artifact_dir, "lib", Sys.iswindows() ? "$name.lib" : "lib$name.a")
artifact_file(artifact_dir, path) = joinpath(artifact_dir, path)
function artifact_library(artifact, name, version)
    dir = joinpath(artifact, Sys.iswindows() ? "bin" : "lib")
    all_names = library_versioned_names(name, version)
    for name in all_names
        path = joinpath(dir, name)
        ispath(path) && return path
    end
    error("Could not find $name ($(join(all_names, ", ", " or "))) in $dir")
end

function artifact_cuda_library(artifact, library, toolkit_release)
    version = cuda_library_version(library, toolkit_release)
    name = get(cuda_library_names, library, library)
    artifact_library(artifact, name, version)
end

# CUDA

# NOTE: we don't use autogenerated JLLs, because we have multiple artifacts and need to
#       decide at run time (i.e. not via package dependencies) which one to use.
const cuda_artifacts = Dict(
    v"11.0" => ()->artifact"CUDA110",
    v"10.2" => ()->artifact"CUDA102",
    v"10.1" => ()->artifact"CUDA101",
    v"10.0" => ()->artifact"CUDA100",
    v"9.2"  => ()->artifact"CUDA92",
    v"9.0"  => ()->artifact"CUDA90",
)

function use_artifact_cuda()
    @debug "Trying to use artifacts..."

    # select compatible artifacts
    if haskey(ENV, "JULIA_CUDA_VERSION")
        wanted_version = VersionNumber(ENV["JULIA_CUDA_VERSION"])
        @debug "Selecting artifacts based on requested version $wanted_version"
        filter!(((version,artifact),) -> version == wanted_version, cuda_artifacts)
    else
        driver_version = release()
        @debug "Selecting artifacts based on driver version $driver_version"
        filter!(((version,artifact),) -> version <= driver_version, cuda_artifacts)
    end

    # download and install
    artifact = nothing
    for release in sort(collect(keys(cuda_artifacts)); rev=true)
        try
            artifact = (release=release, dir=cuda_artifacts[release]())
            break
        catch
        end
    end
    if artifact == nothing
        @debug "Could not find a compatible artifact."
        return false
    end

    __nvdisasm[] = artifact_binary(artifact.dir, "nvdisasm")
    @assert isfile(__nvdisasm[])
    __toolkit_version[] = parse_toolkit_version(__nvdisasm[])

    __libcupti[] = artifact_cuda_library(artifact.dir, "cupti",  artifact.release)
    @assert isfile(__libcupti[])
    __libnvtx[] = artifact_cuda_library(artifact.dir, "nvtx", artifact.release)
    @assert isfile(__libnvtx[])

    __libcudadevrt[] = artifact_static_library(artifact.dir, "cudadevrt")
    @assert isfile(__libcudadevrt[])
    __libdevice[] = artifact_file(artifact.dir, joinpath("share", "libdevice", "libdevice.10.bc"))
    @assert isfile(__libdevice[])

    for library in ("cublas", "cusparse", "cusolver", "cufft", "curand")
        handle = getfield(CUDA, Symbol("__lib$library"))

        handle[] = artifact_cuda_library(artifact.dir, library, artifact.release)
        Libdl.dlopen(handle[])
    end

    @debug "Using CUDA $(__toolkit_version[]) from an artifact at $(artifact.dir)"
    __toolkit_origin[] = :artifact
    use_artifact_cudnn(artifact.release)
    use_artifact_cutensor(artifact.release)
    return true
end

function use_local_cuda()
    @debug "Trying to use local installation..."

    cuda_dirs = find_toolkit()

    let path = find_cuda_binary("nvdisasm", cuda_dirs)
        if path === nothing
            @debug "Could not find nvdisasm"
            return false
        end
        __nvdisasm[] = path
    end

    cuda_version = parse_toolkit_version(__nvdisasm[])
    __toolkit_version[] = cuda_version

    __libcupti[] = find_cuda_library("cupti", cuda_dirs, cuda_version)
    __libnvtx[] = find_cuda_library("nvtx", cuda_dirs, cuda_version)

    let path = find_libcudadevrt(cuda_dirs)
        if path === nothing
            @debug "Could not find libcudadevrt"
            return false
        end
        __libcudadevrt[] = path
    end
    let path = find_libdevice(cuda_dirs)
        if path === nothing
            @debug "Could not find libdevice"
            return false
        end
        __libdevice[] = path
    end

    for library in ("cublas", "cusparse", "cusolver", "cufft", "curand")
        handle = getfield(CUDA, Symbol("__lib$library"))

        path = find_cuda_library(library, cuda_dirs, cuda_version)
        if path === nothing
            @debug "Could not find $library"
            return false
        end
        handle[] = path
    end

    @debug "Found local CUDA $(cuda_version) at $(join(cuda_dirs, ", "))"
    __toolkit_origin[] = :local
    use_local_cudnn(cuda_dirs)
    use_local_cutensor(cuda_dirs)
    return true
end

# CUDNN

# NOTE: we currently support both CUDNN v8 and v7

const cudnn_artifacts = Dict(
    v"11.0" => ()->(artifact"CUDNN_CUDA110", v"8"),
    v"10.2" => ()->(artifact"CUDNN_CUDA102", v"8"),
    v"10.1" => ()->(artifact"CUDNN_CUDA101", v"7"),
    v"10.0" => ()->(artifact"CUDNN_CUDA100", v"7"),
    v"9.2"  => ()->(artifact"CUDNN_CUDA92",  v"7"),
    v"9.0"  => ()->(artifact"CUDNN_CUDA90",  v"7"),
)

function use_artifact_cudnn(release)
    artifact_dir, version = try
        cudnn_artifacts[release]()
    catch ex
        @debug "Could not use CUDNN from artifacts" exception=(ex, catch_backtrace())
        return false
    end

    __libcudnn[] = artifact_library(artifact_dir, "cudnn", version)
    if version >= v"8"
        # HACK: eagerly open CUDNN v8 sublibraries to avoid dlopen discoverability issues
        for sublibrary in ("ops_infer", "ops_train",
                           "cnn_infer", "cnn_train",
                           "adv_infer", "adv_train")
            sublibrary_path = artifact_library(artifact_dir, "cudnn_$(sublibrary)", version)
            Libdl.dlopen(sublibrary_path)
        end
    end
    Libdl.dlopen(__libcudnn[])
    @debug "Using CUDNN from an artifact at $(artifact_dir)"
    return true
end

function use_local_cudnn(cuda_dirs)
    path = find_library("cudnn", v"8"; locations=cuda_dirs)
    if path !== nothing
        # HACK: eagerly open CUDNN v8 sublibraries to avoid dlopen discoverability issues
        for sublibrary in ("ops_infer", "ops_train",
                           "cnn_infer", "cnn_train",
                           "adv_infer", "adv_train")
            sublibrary_path = find_library("cudnn_$(sublibrary)", v"8"; locations=cuda_dirs)
            @assert sublibrary_path !== nothing "Could not find CUDNN sublibrary $sublibrary at $sublibrary_path"
            Libdl.dlopen(sublibrary_path)
        end
    end
    if path === nothing
        path = find_library("cudnn", v"7"; locations=cuda_dirs)
    end
    path === nothing && return false

    Libdl.dlopen(path)
    __libcudnn[] = path
    @debug "Using local CUDNN at $(path)"
    return true
end

# CUTENSOR

const cutensor_artifacts = Dict(
    v"11.0" => ()->artifact"CUTENSOR_CUDA110",
    v"10.2" => ()->artifact"CUTENSOR_CUDA102",
    v"10.1" => ()->artifact"CUTENSOR_CUDA101",
)

function use_artifact_cutensor(release)
    artifact_dir = try
        cutensor_artifacts[release]()
    catch ex
        @debug "Could not use CUTENSOR from artifacts" exception=(ex, catch_backtrace())
        return false
    end

    __libcutensor[] = artifact_library(artifact_dir, "cutensor", v"1")
    Libdl.dlopen(__libcutensor[])
    @debug "Using CUTENSOR from an artifact at $(artifact_dir)"
    return true
end

function use_local_cutensor(cuda_dirs)
    path = find_library("cutensor", v"1"; locations=cuda_dirs)
    path === nothing && return false

    Libdl.dlopen(path)
    __libcutensor[] = path
    @debug "Using local CUTENSOR at $(path)"
    return true
end

function __init_dependencies__()
    found = false

    # CI runs in a well-defined environment, so prefer a local CUDA installation there
    if parse(Bool, get(ENV, "CI", "false")) && !haskey(ENV, "JULIA_CUDA_USE_BINARYBUILDER")
        found = use_local_cuda()
    end

    if !found && parse(Bool, get(ENV, "JULIA_CUDA_USE_BINARYBUILDER", "true"))
        found = use_artifact_cuda()
    end

    if !found
        found = use_local_cuda()
    end

    return found
end

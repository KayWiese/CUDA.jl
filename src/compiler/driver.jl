# compiler driver and main interface

# (::CompilerContext)
const compile_hook = Ref{Union{Nothing,Function}}(nothing)

"""
    compile(dev::CuDevice, f, tt; kwargs...)

Compile a function `f` invoked with types `tt` for device `dev`, returning the compiled
function module respectively of type `CuFuction` and `CuModule`.

For a list of supported keyword arguments, refer to the documentation of
[`cufunction`](@ref).
"""
function compile(dev::CuDevice, @nospecialize(f), @nospecialize(tt); kwargs...)
    CUDAnative.configured || error("CUDAnative.jl has not been configured; cannot JIT code.")
    isa(f, Core.Function) || throw(ArgumentError("Kernel argument to `compile` should be a function."))

    ctx = CompilerContext(f, tt, supported_capability(dev), true; kwargs...)

    if compile_hook[] != nothing
        global globalUnique
        previous_globalUnique = globalUnique
        compile_hook[](ctx)
        globalUnique = previous_globalUnique
    end

    (module_asm, module_entry) = compile(ctx)

    # enable debug options based on Julia's debug setting
    jit_options = Dict{CUDAdrv.CUjit_option,Any}()
    if Base.JLOptions().debug_level == 1
        jit_options[CUDAdrv.GENERATE_LINE_INFO] = true
    elseif Base.JLOptions().debug_level >= 2
        jit_options[CUDAdrv.GENERATE_DEBUG_INFO] = true
    end
    cuda_mod = CuModule(module_asm, jit_options)
    cuda_fun = CuFunction(cuda_mod, module_entry)

    return cuda_fun, cuda_mod
end

# Compile a function to PTX, returning the assembly and an entry point.
# FIXME: this pipeline should be partially reusable from eg. code_llvm
#        also, does the kernel argument belong in the compiler context?
function compile(ctx::CompilerContext; strip_ir_metadata::Bool=false)
    ## high-level code generation (Julia AST)

    @debug "(Re)compiling function" ctx

    check_method(ctx)


    ## low-level code generation (LLVM IR)

    mod, entry = irgen(ctx)

    # link libdevice, if it is necessary
    libdevice = load_libdevice(ctx)
    for f in functions(mod)
        if isdeclaration(f) && intrinsic_id(f)==0 && haskey(functions(libdevice), LLVM.name(f))
            libdevice_copy = LLVM.Module(libdevice)
            link_libdevice!(ctx, mod, libdevice_copy)
            break
        end
    end

    # optimize the IR
    entry = optimize!(ctx, mod, entry)

    check_invocation(ctx, entry)

    # check generated IR
    check_ir(ctx, mod)
    verify(mod)

    if strip_ir_metadata
        strip_debuginfo!(mod)
    end


    ## machine code generation (PTX assembly)

    module_asm = mcgen(ctx, mod, entry)

    return module_asm, LLVM.name(entry)
end

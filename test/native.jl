module GPUModule

using CUDA

export vadd

@target ptx function vadd(a::Ptr{Float32}, b::Ptr{Float32}, c::Ptr{Float32})
    i = blockId_x() + (threadId_x()-1) * numBlocks_x()
    val = unsafe_load(a, i) + unsafe_load(b, i)
    unsafe_store!(c, val, i)

    return nothing
end

end

using CUDA, Base.Test
using GPUModule

@test devcount() > 0

dev = CuDevice(0)
ctx = CuContext(dev)

siz = (3, 4)
len = prod(siz)
a = round(rand(Float32, siz) * 100)
b = round(rand(Float32, siz) * 100)
c = Array(Float32, siz)

@cuda (GPUModule, len, 1) vadd(a, b, c)
@test_approx_eq (a + b) c

@cuda (GPUModule, len, 1) vadd(CuIn(a), CuIn(b), CuOut(c))
@test_approx_eq (a + b) c

ga = CuArray(a)
gb = CuArray(b)
gc = CuArray(Float32, siz)

@cuda (GPUModule, len, 1) vadd(ga, gb, gc)
c = to_host(gc)
@test_approx_eq (a + b) c

free(ga)
free(gb)
free(gc)

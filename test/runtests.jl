module PartitionedPoissonTests

using PartitionedPoisson
using Test

include("../compile/gridap_warmup.jl")

@time @testset "seq 2d" begin poisson(mode=:seq,nc=(4,4),np=(2,2)) end

end # module

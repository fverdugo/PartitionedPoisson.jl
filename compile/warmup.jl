
include("gridap_warmup.jl")

using PartitionedArrays
using PartitionedPoisson

#poisson(mode=:seq,nc=(10,10),np=(2,2))
#poisson(mode=:seq,nc=(10,10,10),np=(2,2,2))
poisson(mode=:mpi,nc=(10,10),np=(1,1))
poisson(mode=:mpi,nc=(10,10,10),np=(1,1,1))

using PackageCompiler

create_sysimage(:PartitionedPoisson,
  sysimage_path=joinpath(@__DIR__,"..","PartitionedPoisson.so"),
  precompile_execution_file=joinpath(@__DIR__,"warmup.jl"))

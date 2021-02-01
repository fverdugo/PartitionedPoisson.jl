# This script is to be executed from the root folder of the repo
julia --project=. --color=yes -e 'using Pkg; Pkg.instantiate()'
julia --project=. -O3 --check-bounds=no --color=yes compile/compile.jl

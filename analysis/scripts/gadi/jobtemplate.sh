#!/bin/bash
#PBS -q {{q}} 
#PBS -l walltime={{walltime}}
#PBS -l ncpus={{ncpus}}
#PBS -l mem={{mem}}
#PBS -N {{{name}}}
#PBS -l wd
#PBS -o {{{o}}}
#PBS -e {{{e}}} 

module load openmpi

$HOME/.julia/bin/mpiexecjl --project={{{projectdir}}} -n {{n}}\
    julia -J {{{sysimage}}} -O3 --check-bounds=no -e\
      'using PartitionedPoisson; poisson(mode=:mpi,nc={{nc}},np={{np}},nr={{nr}},title="{{{title}}}")'

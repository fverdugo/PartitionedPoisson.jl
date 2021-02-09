module PartitionedPoisson

using Gridap
using Gridap.Geometry
using Gridap.FESpaces
using LinearAlgebra
import PartitionedArrays
const PArrays = PartitionedArrays
using MPI
using FileIO

export poisson

u_2d(x) = x[1]+x[2]
u_3d(x) = x[1]+x[2]+x[3]

function poisson(;
  mode::Symbol=:seq,
  nc::Tuple=(10,10,10),
  np::Tuple=(2,2,2),
  nr::Int=1,
  title::String="seq",
  verbose::Bool=false)

  if ! (mode in (:seq,:mpi))
    throw(ArgumentError("mode=$mode is not a valid value for the kw-argument."))
  end

  if mode == :mpi && ! MPI.Initialized()
    MPI.Init()
  end

  backend = mode == :seq ? PArrays.sequential : PArrays.mpi
  parts = PArrays.get_part_ids(backend,np)
  for ir in 1:nr
    str_r = lpad(ir,ceil(Int,log10(nr)),'0')
    title_r = "$(title)_ir$(str_r)"
    _poisson(parts,nc,title_r,ir,verbose)
  end
end

function _poisson(parts,nc,title,ir,verbose)

  domain_2d = (0,1,0,1)
  domain_3d = (0,1,0,1,0,1)
  np = size(parts)

  domain = length(nc) == 3 ? domain_3d : domain_2d
  u = length(nc) == 3 ? u_3d : u_2d
  order = 1

  t = PArrays.PTimer(parts,verbose=verbose)
  PArrays.tic!(t)

  # Partition of the Cartesian ids
  # with ghost layer
  cell_gcis = PArrays.PCartesianIndices(parts,nc,PArrays.with_ghost)
  PArrays.toc!(t,"cell_gcis")

  # Partitioned range of cells
  # with ghost layer
  cell_range = PArrays.PRange(parts,nc,PArrays.with_ghost)
  neighbors = cell_range.exchanger.parts_snd
  ngcells = length(cell_range)
  PArrays.toc!(t,"cell_range")

  # Local discrete models
  model = PArrays.map_parts(cell_gcis) do gcis
    cmin = first(gcis)
    cmax = last(gcis)
    desc = CartesianDescriptor(domain,nc)
    CartesianDiscreteModel(desc,cmin,cmax)
  end
  PArrays.toc!(t,"model")

  # Local FE spaces
  U, V = PArrays.map_parts(model) do model
    reffe = ReferenceFE(lagrangian,Float64,order)
    V = TestFESpace(model,reffe;dirichlet_tags="boundary")
    U = TrialFESpace(u,V)
    U, V
  end
  PArrays.toc!(t,"U, V")

  # Cell-wise local dofs
  cell_to_ldofs, nldofs = PArrays.map_parts(V) do V
    get_cell_dof_ids(V), num_free_dofs(V)
  end
  PArrays.toc!(t,"cell_to_ldofs, nldofs")

  # Find and count number owned dofs
  ldof_to_part, nodofs = PArrays.map_parts(
    cell_range.partition,cell_to_ldofs,nldofs) do partition,cell_to_ldofs,nldofs

    ldof_to_part = fill(Int32(0),nldofs)
    cache = array_cache(cell_to_ldofs)
    for cell in 1:length(cell_to_ldofs)
      owner = partition.lid_to_part[cell]
      ldofs = getindex!(cache,cell_to_ldofs,cell)
      for ldof in ldofs
        if ldof>0
          #TODO this simple approach concentrates dofs
          # in the last part and creates inbalances
          ldof_to_part[ldof] = max(owner,ldof_to_part[ldof])
        end
      end
    end
    nodofs = count(p->p==partition.part,ldof_to_part)
    ldof_to_part, nodofs
  end
  PArrays.toc!(t,"ldof_to_part, nodofs")

  # Find the global range of owned dofs
  first_gdof, ngdofsplus1 = PArrays.xscan(+,reduce,nodofs,init=1)
  ngdofs = ngdofsplus1 - 1
  PArrays.toc!(t,"first_gdof, ngdofs")

  # Distribute gdofs to owned ones
  ldof_to_gdof = PArrays.map_parts(
    parts,first_gdof,ldof_to_part) do part,first_gdof,ldof_to_part

    offset = first_gdof-1
    ldof_to_gdof = Vector{Int}(undef,length(ldof_to_part))
    odof = 0
    gdof = 0
    for (ldof,owner) in enumerate(ldof_to_part)
      if owner == part
        odof += 1
        ldof_to_gdof[ldof] = odof
      else
        ldof_to_gdof[ldof] = gdof
      end
    end
    for (ldof,owner) in enumerate(ldof_to_part)
      if owner == part
        ldof_to_gdof[ldof] += offset
      end
    end
    ldof_to_gdof
  end
  PArrays.toc!(t,"ldof_to_gdof (owned)")

  # Create cell-wise global dofs
  cell_to_gdofs = PArrays.map_parts(
    parts,
    ldof_to_gdof,cell_to_ldofs,cell_range.partition) do part,
    ldof_to_gdof,cell_to_ldofs,partition

    cache = array_cache(cell_to_ldofs)
    ncells = length(cell_to_ldofs)
    ptrs = Vector{Int32}(undef,ncells+1)
    for cell in 1:ncells
      ldofs = getindex!(cache,cell_to_ldofs,cell)
      ptrs[cell+1] = length(ldofs)
    end
    PArrays.length_to_ptrs!(ptrs)
    ndata = ptrs[end]-1
    data = Vector{Int}(undef,ndata)
    gdof = 0
    for cell in partition.oid_to_lid
      ldofs = getindex!(cache,cell_to_ldofs,cell)
      p = ptrs[cell]-1
      for (i,ldof) in enumerate(ldofs)
        if ldof > 0 && ldof_to_gdof[ldof] != gdof
          data[i+p] = ldof_to_gdof[ldof]
        end
      end
    end
    PArrays.Table(data,ptrs)
  end
  PArrays.toc!(t,"cell_to_gdofs (owned)")

  # Exchange the global dofs
  PArrays.exchange!(cell_to_gdofs,cell_range.exchanger)
  PArrays.toc!(t,"cell_to_gdofs (ghost)")

  # Distribute global dof ids also to ghost
  PArrays.map_parts(
    parts,
    cell_to_ldofs,cell_to_gdofs,ldof_to_gdof,ldof_to_part,cell_range.partition) do part,
    cell_to_ldofs,cell_to_gdofs,ldof_to_gdof,ldof_to_part,partition

    gdof = 0
    cache = array_cache(cell_to_ldofs)
    for cell in partition.hid_to_lid
      ldofs = getindex!(cache,cell_to_ldofs,cell)
      p = cell_to_gdofs.ptrs[cell]-1
      for (i,ldof) in enumerate(ldofs)
        if ldof > 0 && ldof_to_part[ldof] == partition.lid_to_part[cell]
          ldof_to_gdof[ldof] = cell_to_gdofs.data[i+p]
        end
      end
    end
  end
  PArrays.toc!(t,"ldof_to_gdof (ghost)")

  # Setup dof partition
  dof_partition = PArrays.map_parts(parts,ldof_to_gdof,ldof_to_part) do part,ldof_to_gdof,ldof_to_part
    PArrays.IndexSet(part,ldof_to_gdof,ldof_to_part)
  end
  PArrays.toc!(t,"dof_partition")

  # Setup dof exchanger
  dof_exchanger = PArrays.Exchanger(dof_partition,neighbors)
  PArrays.toc!(t,"dof_exchanger")

  # Setup dof range
  dofs = PArrays.PRange(ngdofs,dof_partition,dof_exchanger)
  PArrays.toc!(t,"dofs")

  # Setup Integration (only for owned cells)
  Ω, dΩ = PArrays.map_parts(cell_range.partition,model) do partition, model
    Ω = Triangulation(model,partition.oid_to_lid)
    dΩ = Measure(Ω,2*order)
    Ω, dΩ
  end
  PArrays.toc!(t,"Ω, dΩ")

  # Integrate the coo vectors
  I,J,C,vec = PArrays.map_parts(Ω,dΩ,U,V,ldof_to_gdof) do Ω,dΩ,U,V,ldof_to_gdof
    dv = get_cell_shapefuns(V)
    du = get_cell_shapefuns_trial(U)
    cellmat = ∫( ∇(du)⋅∇(dv) )dΩ
    cellvec = 0
    uhd = zero(U)
    matvecdata = collect_cell_matrix_and_vector(cellmat,cellvec,uhd)
    assem = SparseMatrixAssembler(U,V)
    ncoo = count_matrix_and_vector_nnz_coo(assem,matvecdata)
    I = zeros(Int,ncoo)
    J = zeros(Int,ncoo)
    C = zeros(Float64,ncoo)
    vec = zeros(Float64,num_free_dofs(V))
    fill_matrix_and_vector_coo_numeric!(I,J,C,vec,assem,matvecdata)
    I,J,C,vec
  end
  PArrays.toc!(t,"I,J,C,vec")

  PArrays.map_parts(I,J,ldof_to_gdof) do I,J,ldof_to_gdof
    for i in 1:length(I)
      I[i] = ldof_to_gdof[I[i]]
      J[i] = ldof_to_gdof[J[i]]
    end
  end
  PArrays.toc!(t,"I,J (global)")

  # Find the ghost rows
  hrow_to_hdof = PArrays.touched_hids(dofs,I)
  PArrays.toc!(t,"hrow_to_hdof")

  hrow_to_gid, hrow_to_part = PArrays.map_parts(
    hrow_to_hdof, dof_partition) do hrow_to_hdof, dof_partition
    hrow_to_ldof = view(dof_partition.hid_to_lid,hrow_to_hdof)
    hrow_to_gdof = dof_partition.lid_to_gid[hrow_to_ldof]
    hrow_to_part = dof_partition.lid_to_part[hrow_to_ldof]
    hrow_to_gdof, hrow_to_part
  end
  PArrays.toc!(t,"hrow_to_gid, hrow_to_part")

  # Create the range for rows
  rows = PArrays.PRange(
    parts,ngdofs,nodofs,first_gdof,hrow_to_gid,hrow_to_part,neighbors)
  PArrays.toc!(t,"rows")

  # Move values to the owner part
  # since we have integrated only over owned cells
  PArrays.assemble!(I,J,C,rows)
  PArrays.toc!(t,"I,J,C (assemble!)")

  # Find the ghost cols
  hcol_to_hdof = PArrays.touched_hids(dofs,J)
  PArrays.toc!(t,"hcol_to_hdof")

  hcol_to_gid, hcol_to_part = PArrays.map_parts(
    hcol_to_hdof, dof_partition) do hcol_to_hdof, dof_partition
    hcol_to_ldof = view(dof_partition.hid_to_lid,hcol_to_hdof)
    hcol_to_gdof = dof_partition.lid_to_gid[hcol_to_ldof]
    hcol_to_part = dof_partition.lid_to_part[hcol_to_ldof]
    hcol_to_gdof, hcol_to_part
  end
  PArrays.toc!(t,"hcol_to_gid, hcol_to_part")

  # Create the range for cols
  cols = PArrays.PRange(
    parts,ngdofs,nodofs,first_gdof,hcol_to_gid,hcol_to_part,neighbors)
  PArrays.toc!(t,"cols")

  # Create the sparse matrix
  A_exchanger = PArrays.empty_exchanger(parts)
  A = PArrays.PSparseMatrix(I,J,C,rows,cols,A_exchanger,ids=:global)
  PArrays.toc!(t,"A")

  # Rhs aligned with the FESpace
  dof_values = PArrays.PVector(vec,dofs)
  PArrays.toc!(t,"dof_values")

  # Allocate rhs aligned with the matrix
  b = PArrays.PVector(0.0,rows)
  PArrays.toc!(t,"b (allocate)")

  # Fill rhs
  # TODO A more elegant way of doing this?
  PArrays.map_parts(
    b.values,dof_values.values,rows.partition,dofs.partition,first_gdof) do b1, b2, p1, p2, first_gdof
    offset = first_gdof - 1
    for i in p1.oid_to_lid
      gdof = p1.lid_to_gid[i]
      odof = gdof-offset
      ldof = p2.oid_to_lid[odof]
      b1[i] = b2[ldof]
    end
    for i in p1.hid_to_lid
      gdof = p1.lid_to_gid[i]
      ldof = p2.gid_to_lid[gdof]
      b1[i] = b2[ldof]
    end
  end
  PArrays.toc!(t,"b (fill)")

  # Import and add remote contributions
  PArrays.assemble!(b)
  PArrays.toc!(t,"b (assemble!)")

  # Interpolate exact solution
  # (this is aligned with the FESpace)
  PArrays.map_parts(dof_values.values,U) do dof_values,U
    interpolate!(u,dof_values,U)
  end

  # Allocate solution
  # aligned with the matrix
  x = PArrays.PVector(0.0,cols)
  PArrays.toc!(t,"x (allocate)")

  #### Fill
  #### only needed to fill owned values
  #### since A*x will do the exchange
  x .= dof_values
  PArrays.toc!(t,"x (fill)")

  r = similar(b)
  PArrays.toc!(t,"r (allocate)")

  mul!(r,A,x)
  PArrays.toc!(t,"r (A*x)")

  r .= r .- b
  PArrays.toc!(t,"r (-b)")

  errnorm = norm(r)
  PArrays.toc!(t,"norm(r)")

  display(t)

  PArrays.map_main(t.data) do data
    out = Dict{String,Any}()
    merge!(out,data)
    out["errnorm"] = errnorm
    out["ngdofs"] = ngdofs
    out["ngcells"] = ngcells
    out["nc"] = nc
    out["np"] = np
    out["ir"] = ir
    save("$title.bson",out)
  end

  nothing
end

end # module

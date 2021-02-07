
using Mustache
using DrWatson

jobname(args...) = replace(savename(args...;connector=""),"="=>"")

np2mem = Dict(
  2 => 180,
  3 => 190,
  4 => 380,
  6 => 378,
  7 => 601,
  8 => 400,
  11 => 1000,
  13 => 1500,
  16 => 1500,
  21 => 3000, )
          
function jobdict(params)
  ncx = params[:ncx]
  npx = params[:npx]
  nr = params[:nr]
  np = (npx,npx,npx)
  nc = (ncx,ncx,ncx)
  Dict(
  "q" => "normal",
  "o" => datadir("gadi",jobname(params,"o.txt")),
  "e" => datadir("gadi",jobname(params,"e.txt")),
  "walltime" => "00:15:00",
  "ncpus" => prod(np)>48 ? ceil(Int,prod(np)/48)*48 : prod(np),
  "mem" => "$(np2mem[first(np)])gb",#"$(ceil(Int,(14/8)*prod(np)))gb",
  "name" => jobname(params),
  "nc" => nc,
  "n" => prod(np),
  "np" => np,
  "nr" => nr,
  "projectdir" => projectdir(),
  "title" => datadir("gadi",jobname(params)),
  "sysimage" => projectdir("$(projectname()).so")
  )
end

allparams = Dict(
 :npx => map(i->ceil(Int,2^(i/3)*2),[0,1,3,4,5,6,7,8,9,10]),
 :ncx => 300,
 :nr => 3
 )

template = read(scriptsdir("gadi","jobtemplate.sh"),String)

dicts = dict_list(allparams)

for params in dicts
  jobfile = datadir("gadi",jobname(params,"sh"))
  open(jobfile,"w") do io
    render(io,template,jobdict(params))
  end
end


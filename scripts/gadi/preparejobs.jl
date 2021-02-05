
using Mustache
using DrWatson

jobname(args...) = savename(args...;connector="")
          
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
  "walltime" => "00:05:00",
  "ncpus" => prod(np),
  "mem" => "20gb",
  "name" => jobname(params),
  "nc" => nc,
  "n" => prod(np),
  "np" => np,
  "nr" => nr,
  "projectdir" => projectdir(),
  "sysimage" => projectdir("$(projectname()).so")
  )
end

allparams = Dict(
 :npx => [2,3,4],
 :ncx => 250,
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


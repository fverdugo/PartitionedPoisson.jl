# Assumes that you have just included postprojobs.jl

using Plots
x = (df.np).^3
y = sum(collect(eachcol(dft)))
plt = plot(x,y,
   #size=(400,250),
   thickness_scaling = 1.2,
   xaxis=("Number of cores",:log),
   yaxis=("Wall time [s]",:log),
   shape=:square,
   label="Measured",
   legend=:outertopright,
   markerstrokecolor=:white,
  )
x1 = first(x)
y1 = first(y)
s = y1.*(x1./x)
plot!(x,s,xaxis=:log, yaxis=:log, label="Ideal")
l = first(df.ngdofs)/25e3
plot!([l,l],collect(ylims(plt)),xaxis=:log, yaxis=:log,linestyle=:dash, label="25KDOFs/core")

savefig(plotsdir("gadi","total_scaling.pdf"))

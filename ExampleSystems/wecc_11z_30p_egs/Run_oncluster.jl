case = dirname(@__FILE__);

import Pkg
# Pkg.instantiate()
# println("Activating Package")

model_folder = abspath(joinpath(pwd(), "..", ".."))

Pkg.activate(model_folder)

include(string(pwd(),"/run.jl"));

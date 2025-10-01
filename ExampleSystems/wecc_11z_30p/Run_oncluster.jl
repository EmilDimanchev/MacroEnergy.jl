case = dirname(@__FILE__);

import Pkg
# Pkg.instantiate()
# println("Activating Package")

Pkg.activate("/home/ed0400/1_Macro")

include("/home/ed0400/1_Macro/ExampleSystems/wecc_11z_30p/run.jl");

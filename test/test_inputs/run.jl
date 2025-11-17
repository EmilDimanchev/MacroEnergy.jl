using MacroEnergy
using HiGHS
using Pkg
try Pkg.add("Gurobi"); using Gurobi; catch e end
optim = is_gurobi_available() ? Gurobi.Optimizer : HiGHS.Optimizer
println()

system = MacroEnergy.load_system(@__DIR__)
model = MacroEnergy.generate_model(system)
MacroEnergy.set_optimizer(model, optim)
MacroEnergy.optimize!(model)
macro_objval = MacroEnergy.objective_value(model)
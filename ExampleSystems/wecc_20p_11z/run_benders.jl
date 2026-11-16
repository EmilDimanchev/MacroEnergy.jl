using MacroEnergy
using Gurobi
using Dates

# Name the output folder after today's date (mmddyy), like the batch folders made
# by run_experiments.sh; Macro then appends _001, _002, ... to avoid overwriting.
# Experiment case folders set their own OutputDir (with OverwriteResults) and are
# left alone.
let settings_file = joinpath(@__DIR__, "settings", "macro_settings.json")
    text = read(settings_file, String)
    if !occursin(r"\"OverwriteResults\"\s*:\s*true", text)
        occursin(r"\"OutputDir\"\s*:", text) || error("No OutputDir in $settings_file")
        tag = Dates.format(Dates.today(), "mmddyy")
        new_text = replace(text, r"(\"OutputDir\"\s*:\s*)\"[^\"]*\"" => SubstitutionString("\\1\"$tag\""))
        new_text != text && write(settings_file, new_text)
    end
end

(system, results) = run_case(@__DIR__;
    planning_optimizer=Gurobi.Optimizer,
    subproblem_optimizer=Gurobi.Optimizer,
    planning_optimizer_attributes=("Method" => 2, "Crossover" => 0, "BarConvTol" => 1e-3, "BarHomogeneous" => 1, "NumericFocus" => 1),
    subproblem_optimizer_attributes=("Method" => 2, "Crossover" => 1, "BarConvTol" => 1e-3));

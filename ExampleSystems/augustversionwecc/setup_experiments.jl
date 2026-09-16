#!/usr/bin/env julia
#
# setup_experiments.jl — scaffold (and optionally submit) one SLURM job per
# experiment case.
#
# Each experiment is defined by a settings file in
#     settings/experiments_settings/case_settings_<name>.json
# List the <name>s you want to run in `cases` below. For each one this script
# creates a thin sibling run folder next to this template (e.g. ../<name>) that
# shares the heavy inputs (system/, assets/, ...) via symlinks and uses the
# chosen experiment file as its settings/case_settings.json. Each case then
# runs as its own SLURM job with the shared config in benders_jobscript.sh.
#
# Because each case has its own folder, results/, logs, and the run .log never
# collide. No changes to the model code are required.
#
# On the cluster, launch it via ./run_experiments.sh (which loads the Julia
# module first). You can also run it directly (plain Base Julia, no packages):
#     julia setup_experiments.jl            # preview: scaffold + print sbatch commands
#     SUBMIT=true julia setup_experiments.jl # scaffold + actually submit
#
# Typical flow: preview first (submit off) to scaffold and check the folders,
# then submit for real. See run_experiments.sh for the SUBMIT/OVERWRITE switches.

# ── Configuration ─────────────────────────────────────────────────────────────
cases = [
    "nocd_nodi_noel_nocap",
    "nocd_nodi_noel_cap",
    "cd_nodi_noel_cap",
    "cd_di_noel_cap",
    "cd_di_el_cap",
]

# submit/overwrite are read from the environment so the run_experiments.sh
# launcher can control them without editing this file. Both default to false,
# so running `julia setup_experiments.jl` directly is a safe preview (scaffold +
# print the sbatch commands, submit nothing).
_envflag(k) = lowercase(get(ENV, k, "false")) in ("1", "true", "yes")
submit    = _envflag("SUBMIT")      # SUBMIT=true    → actually sbatch each case
overwrite = _envflag("OVERWRITE")   # OVERWRITE=true → delete & rebuild existing case folders

# ── Paths ─────────────────────────────────────────────────────────────────────
const TEMPLATE        = @__DIR__                 # this template folder (e.g. wecc_20p_11z)
const TEMPLATE_NAME   = basename(TEMPLATE)
const PARENT          = dirname(TEMPLATE)        # cases are created here, as siblings
const EXPERIMENTS_DIR = joinpath(TEMPLATE, "settings", "experiments_settings")
const JOBSCRIPT       = joinpath(TEMPLATE, "benders_jobscript.sh")

# Heavy shared inputs are symlinked; the tiny per-case files are copied.
const LINK_ITEMS    = ["system", "assets", "system_data.json", "locations.json"]
const COPY_RUNNERS  = ["Run_benders_oncluster.jl", "run_benders.jl"]
const COPY_SETTINGS = ["macro_settings.json", "benders_settings.json"]  # shared, non-case-specific

# ── Build one case folder ─────────────────────────────────────────────────────
# Returns (case_dir, built) where `built` is false if an existing folder was reused.
function build_case(name::AbstractString)
    src_settings = joinpath(EXPERIMENTS_DIR, "case_settings_$(name).json")
    isfile(src_settings) || error("Missing settings file: $src_settings")

    case_dir = joinpath(PARENT, name)
    if ispath(case_dir)
        if overwrite
            rm(case_dir; recursive=true)
        else
            @info "Reusing existing case folder (set overwrite=true to rebuild): $case_dir"
            return case_dir, false
        end
    end

    mkpath(case_dir)

    # Symlink the heavy shared inputs. The target is relative (../<template>/item)
    # so the tree stays valid across machines (laptop vs cluster).
    for item in LINK_ITEMS
        target = joinpath(TEMPLATE, item)
        ispath(target) || error("Template missing '$item': $target")
        symlink(joinpath("..", TEMPLATE_NAME, item), joinpath(case_dir, item))
    end

    # Copy the tiny runner scripts
    for item in COPY_RUNNERS
        cp(joinpath(TEMPLATE, item), joinpath(case_dir, item))
    end

    # Settings: copy the shared settings, then drop in the chosen experiment file
    # as this case's case_settings.json.
    settings_dir = joinpath(case_dir, "settings")
    mkpath(settings_dir)
    for item in COPY_SETTINGS
        cp(joinpath(TEMPLATE, "settings", item), joinpath(settings_dir, item))
    end
    cp(src_settings, joinpath(settings_dir, "case_settings.json"))

    # Marker (lets tooling tell generated cases apart) + slurm log dir
    touch(joinpath(case_dir, ".macro_case"))
    mkpath(joinpath(case_dir, "logs"))

    return case_dir, true
end

# ── Submit one case ───────────────────────────────────────────────────────────
function submit_case(name::AbstractString, case_dir::AbstractString)
    cmd = `sbatch --job-name=wecc_$(name) --chdir=$(case_dir) $(JOBSCRIPT)`
    if submit
        run(cmd)
    else
        println("[dry-run] ", cmd)
    end
end

# ── Run ───────────────────────────────────────────────────────────────────────
isdir(EXPERIMENTS_DIR) || error("Experiments settings folder not found: $EXPERIMENTS_DIR")
isfile(JOBSCRIPT)      || error("Jobscript not found: $JOBSCRIPT")

for name in cases
    case_dir, built = build_case(name)
    println(built ? "Prepared case: $case_dir" : "Using case:    $case_dir")
    submit_case(name, case_dir)
end

println("\nDone. ", submit ? "Submitted" : "Scaffolded (submit=false, nothing submitted)",
        " $(length(cases)) case(s).")

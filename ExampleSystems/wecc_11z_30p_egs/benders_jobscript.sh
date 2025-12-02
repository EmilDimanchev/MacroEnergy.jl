#!/bin/bash

#SBATCH --job-name=ed_sl_bd        # create a short name for your job
#SBATCH --nodes=1                # node count
#SBATCH --ntasks=4              # total number of tasks across all nodes
#SBATCH --ntasks-per-node=4
#SBATCH --cpus-per-task=24
#SBATCH --output=slurm-%j.out 
#SBATCH --mem=500GB              # total memory
#SBATCH --constraint=amd
#SBATCH --time=12:00:00          # total run time limit (HH:MM:SS)
#SBATCH --mail-type=all          # send email when job ends
#SBATCH --mail-user=ed0400@princeton.edu


module purge
module load gurobi/12.0.0
module load julia/1.12.1

julia Run_benders_oncluster.jl
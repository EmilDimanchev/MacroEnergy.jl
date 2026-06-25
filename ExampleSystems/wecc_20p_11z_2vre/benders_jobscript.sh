#!/bin/bash

#SBATCH --job-name=ed_sl_bd20w        
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=400GB
#SBATCH --output=logs/slurm-%j.out
#SBATCH --time=20:00:00          # (HH:MM:SS)
#SBATCH --mail-type=all          
#SBATCH --mail-user=ed0400@princeton.edu

module purge
module load gurobi/12.0.0
module load julia/1.12.1

julia Run_benders_oncluster.jl
#!/bin/bash

#SBATCH --job-name=ed_sl_bd        # create a short name for your job
#SBATCH --nodes=1                # node count
#SBATCH --ntasks=5               # total number of tasks across all nodes
#SBATCH --ntasks-per-node=5
#SBATCH --cpus-per-task=32
#SBATCH --output=slurm-%j.out 
#SBATCH --mem=120GB              # total memory
#SBATCH --time=0:30:00          # total run time limit (HH:MM:SS)
#SBATCH --mail-type=all          # send email when job ends
#SBATCH --mail-user=ed0400@princeton.edu


module purge
module load gurobi/12.0.0
module load julia/1.11.1

julia Run_oncluster.jl
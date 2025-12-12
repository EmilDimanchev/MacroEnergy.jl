#!/bin/bash

#SBATCH --job-name=ed_sl_bd        
#SBATCH --nodes=6                
#SBATCH --ntasks=120              
#SBATCH --ntasks-per-node=20
#SBATCH --cpus-per-task=1
#SBATCH --output=slurm-%j.out 
#SBATCH --mem=200GB              
#SBATCH --constraint=amd
#SBATCH --time=24:00:00          # (HH:MM:SS)
#SBATCH --mail-type=all          
#SBATCH --mail-user=ed0400@princeton.edu


module purge
module load gurobi/12.0.0
module load julia/1.12.1

julia Run_benders_oncluster.jl
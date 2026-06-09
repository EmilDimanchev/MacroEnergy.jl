#!/bin/bash

#SBATCH --job-name=ed_sl_bd20w        
#SBATCH --nodes=1                
#SBATCH --ntasks=100              
#SBATCH --ntasks-per-node=100
#SBATCH --cpus-per-task=1
#SBATCH --mem=400GB    
#SBATCH --output=slurm-%j.out 
#SBATCH --time=12:00:00          # (HH:MM:SS)
#SBATCH --mail-type=all          
#SBATCH --mail-user=ed0400@princeton.edu

module purge
module load gurobi/12.0.0
module load julia/1.12.1

julia Run_benders_oncluster.jl
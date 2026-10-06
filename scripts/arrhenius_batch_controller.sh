#!/bin/bash
#SBATCH -A naiss2026-3-127-cpu
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=24G
#SBATCH --time=3-00:00:00
#SBATCH --job-name=ephys-archive-batch

set -euo pipefail
BATCH="${1:?usage: sbatch arrhenius_batch_controller.sh <batch-directory>}"
python3 -u "$BATCH/snapshot/scripts/arrhenius_batch.py" run "$BATCH"

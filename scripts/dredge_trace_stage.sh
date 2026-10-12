#!/bin/bash
#SBATCH -A naiss2026-3-127-cpu
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=24G
#SBATCH --time=06:00:00
#SBATCH --job-name=dredge-trace-stage
set -euo pipefail
U="/nobackup/proj/disk/dmclab/personal/${USER:?}"
ROOT="$U/baseline_pilots/dredge100_original_trace_20261009"
test "${SLURM_ARRAY_TASK_ID:?Submit array 0-4}" -ge 0 && test "$SLURM_ARRAY_TASK_ID" -le 4
cd "$ROOT"
sha256sum -c source_checksums.sha256
sha256sum -c stage_checksums.sha256
python3 -B -u "$ROOT/source/dredge_trace_stage.py" --user-root "$U" --index "$SLURM_ARRAY_TASK_ID"

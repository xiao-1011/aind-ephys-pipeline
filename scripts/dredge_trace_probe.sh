#!/bin/bash
#SBATCH -A naiss2026-3-127-cpu
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=16G
#SBATCH --time=02:00:00
#SBATCH --job-name=dredge-trace-probe
set -euo pipefail
U="/nobackup/proj/disk/dmclab/personal/${USER:?}"
ROOT="$U/baseline_pilots/dredge100_original_trace_20261009"
SOURCE="$ROOT/source"
test "${SLURM_ARRAY_TASK_ID:?Submit as array 0-4}" -ge 0 && test "$SLURM_ARRAY_TASK_ID" -le 4
cd "$ROOT"
sha256sum -c source_checksums.sha256
python3 -B "$SOURCE/dredge_trace_probe.py" --user-root "$U" --index "$SLURM_ARRAY_TASK_ID"

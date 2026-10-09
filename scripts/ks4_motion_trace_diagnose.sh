#!/bin/bash
# Read-only diagnostic of saved/live traces on array indices 0-2 (groups 0-2).
#SBATCH -A naiss2026-3-127-cpu
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --time=01:00:00
#SBATCH --job-name=ks4-trace-diagnose

set -euo pipefail
U="/nobackup/proj/disk/dmclab/personal/${USER:?}"
T="$U/baseline_pilots/ks4_native_motion_trace_test_20261008"
D="$T/diagnostics_20261009"
PILOT="$U/baseline_pilots/ks4_followups_20261008_3526824"
BASE="$U/apptainer_cache/ghcr.io-allenneuraldynamics-aind-ephys-pipeline-base-1.4.0.img"
test -n "${SLURM_ARRAY_TASK_ID:?Submit array 0-2}"
test "$SLURM_ARRAY_TASK_ID" -ge 0 && test "$SLURM_ARRAY_TASK_ID" -le 2
test -f "$BASE"
test "$(sha256sum "$T/source/ks4_motion_trace_replay.py" | cut -d' ' -f1)" = \
    43eb4d0e78060e942df16d04680db86ddb9e01a1292910390b9f2b692e130efd
cd "$D"
sha256sum -c diagnostic_checksums.sha256
export NUMBA_CACHE_DIR="$D/cache_${SLURM_ARRAY_TASK_ID}" OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1
mkdir -p "$NUMBA_CACHE_DIR"
apptainer exec -B "$U,$PILOT:$PILOT:ro,$U/raw_ecephys:$U/raw_ecephys:ro,$U/session_archives:$U/session_archives:ro" \
    "$BASE" python -u "$D/ks4_motion_trace_diagnose.py" --user-root "$U" --group "$SLURM_ARRAY_TASK_ID"

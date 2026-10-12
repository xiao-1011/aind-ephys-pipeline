#!/bin/bash
#SBATCH -A naiss2026-3-127-cpu
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=16G
#SBATCH --time=00:30:00
#SBATCH --job-name=dredge-trace-check
set -euo pipefail
U="/nobackup/proj/disk/dmclab/personal/${USER:?}"
ROOT="$U/baseline_pilots/dredge100_original_trace_20261009"
SOURCE="$ROOT/source_v2"
BASE="$U/apptainer_cache/ghcr.io-allenneuraldynamics-aind-ephys-pipeline-base-1.4.0.img"
INITIAL="$U/baseline_pilots/20261008_ks4_builtin64_vr1520260318_g0_ce4972d"
PRIOR="$U/baseline_pilots/ks4_native_motion_trace_test_20261008"
cd "$ROOT"
sha256sum -c source_checksums.sha256
sha256sum -c stage_checksums.sha256
sha256sum -c source_v2_checksums.sha256
export HF_HOME="$ROOT/hf-cache" OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1
BINDS="$U,$INITIAL:$INITIAL:ro,$PRIOR:$PRIOR:ro,$ROOT/staged:$ROOT/staged:ro,$U/raw_ecephys:$U/raw_ecephys:ro,$U/session_archives:$U/session_archives:ro,$U/batch_runs:$U/batch_runs:ro"
apptainer exec -B "$BINDS" "$BASE" python -u "$SOURCE/dredge_trace_preflight.py" "$U"

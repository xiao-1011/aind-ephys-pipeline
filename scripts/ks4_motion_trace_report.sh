#!/bin/bash
#SBATCH -A naiss2026-3-127-cpu
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --time=04:00:00
#SBATCH --job-name=ks4-trace-report
set -euo pipefail
U="/nobackup/proj/disk/dmclab/personal/${USER:?}"
ROOT="$U/baseline_pilots/ks4_native_motion_trace_test_20261008"
BASE="$U/apptainer_cache/ghcr.io-allenneuraldynamics-aind-ephys-pipeline-base-1.4.0.img"
export HF_HOME="$ROOT/hf-cache" OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1
sacct -j "${KS4_TRACE_ARRAY_JOB:?Pass array job ID}" --format=JobID,State,ExitCode,Elapsed,MaxRSS --parsable2 > "$ROOT/job_accounting.txt"
cd "$ROOT"
PILOT="$U/baseline_pilots/ks4_followups_20261008_3526824"
apptainer exec -B "$U,$PILOT:$PILOT:ro,$U/raw_ecephys:$U/raw_ecephys:ro,$U/session_archives:$U/session_archives:ro" "$BASE" \
    python -u "${KS4_TRACE_REPORT_SCRIPT:-$ROOT/source/ks4_motion_trace_replay.py}" report --user-root "$U"
printf 'passed\n' > "$ROOT/report_complete"
cat "$ROOT/REPORT.md"

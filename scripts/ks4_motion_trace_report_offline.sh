#!/bin/bash
# Run new isolated report only after all 16 replay arms complete.
#SBATCH -A naiss2026-3-127-cpu
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --time=04:00:00
#SBATCH --job-name=ks4-trace-report-local

set -euo pipefail
U="/nobackup/proj/disk/dmclab/personal/${USER:?}"
T="$U/baseline_pilots/ks4_native_motion_trace_test_20261008"
D="$T/diagnostics_20261009"
PILOT="$U/baseline_pilots/ks4_followups_20261008_3526824"
BASE="$U/apptainer_cache/ghcr.io-allenneuraldynamics-aind-ephys-pipeline-base-1.4.0.img"
test ! -e "$T/report_20261009" && test ! -L "$T/report_20261009"
test "$(find "$T/cohort07" "$T/cohort08" "$T/cohort09" -name curation_complete -type f | wc -l)" = 16
for group in 1 2; do
    test -f "$T/cohort08/20260719/vr2520260719_g0/group$group/curation_complete"
done
cd "$T"
sha256sum -c report_source_checksums.sha256
cd "$D"
sha256sum -c offline_checksums.sha256
test -f "$BASE"
export HF_HOME="$T/hf-cache" OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1
apptainer exec -B "$U,$PILOT:$PILOT:ro,$U/raw_ecephys:$U/raw_ecephys:ro,$U/session_archives:$U/session_archives:ro" \
    "$BASE" python -u "$D/ks4_motion_trace_report_offline.py" --user-root "$U"
cat "$T/report_20261009/REPORT.md"

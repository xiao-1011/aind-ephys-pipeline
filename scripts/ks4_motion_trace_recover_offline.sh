#!/bin/bash
# Complete ONLY index 6 after pinned-model local verification; no API HEAD call.
#SBATCH -A naiss2026-3-127-cpu
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=24
#SBATCH --mem=96G
#SBATCH --time=12:00:00
#SBATCH --job-name=ks4-trace-recover6

set -euo pipefail
U="/nobackup/proj/disk/dmclab/personal/${USER:?}"
T="$U/baseline_pilots/ks4_native_motion_trace_test_20261008"
D="$T/diagnostics_20261009"
PILOT="$U/baseline_pilots/ks4_followups_20261008_3526824"
BASE="$U/apptainer_cache/ghcr.io-allenneuraldynamics-aind-ephys-pipeline-base-1.4.0.img"
PATCHED="$U/containers/aind-ephys-curation_1.4.0_si4830.sif"
test "${SLURM_ARRAY_TASK_ID:?Submit as array index 6 only}" = 6
test -f "$BASE" && test -f "$PATCHED"
test "$(sha256sum "$PATCHED" | cut -d' ' -f1)" = \
    c5c211a7a5e50bdebd1cacbc20236a19d42c6555813ec7776ee07401b2f76993
test "$(sha256sum "$T/source/ks4_motion_trace_replay.py" | cut -d' ' -f1)" = \
    43eb4d0e78060e942df16d04680db86ddb9e01a1292910390b9f2b692e130efd
cd "$D"
sha256sum -c offline_checksums.sha256
REL=cohort08/20260719/vr2520260719_g0
NAME=block0_imec0.ap_recording1_group2
TASK="$T/$REL/group2"
test -d "$TASK/corrected_binary" && test -f "$TASK/corrected_recording.json"
for name in curation_complete provenance.json control_binary uncorrected native_motion_interpolated; do
    test ! -e "$TASK/$name" && test ! -L "$TASK/$name"
done
BINDS="$U,$PILOT:$PILOT:ro,$U/raw_ecephys:$U/raw_ecephys:ro,$U/session_archives:$U/session_archives:ro"
export N_JOBS_EXT=24 OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1
export HF_HOME="$T/hf-cache"
export NUMBA_CACHE_DIR="$D/recovery_cache_offline_6"
export MPLCONFIGDIR="$D/mpl_offline_6"
mkdir -p "$NUMBA_CACHE_DIR" "$MPLCONFIGDIR"
apptainer exec -B "$BINDS" "$BASE" python -u "$D/ks4_motion_trace_recover_offline.py" \
    --user-root "$U" --index 6 --offline-model-check
export N_JOBS_EXT=12
for ARM in uncorrected native_motion_interpolated; do
    test -f "$TASK/$ARM/postprocessing_complete" && test -f "$TASK/$ARM/curation_params.json"
    cd "$TASK/$ARM/curation/capsule/code"
    apptainer exec -B "$BINDS" "$PATCHED" python -u run_capsule.py --params "$(cat "$TASK/$ARM/curation_params.json")"
    test -f "$TASK/$ARM/curation/capsule/results/unit_labels_${NAME}.csv"
done
apptainer exec -B "$BINDS" "$PATCHED" python -u "$D/ks4_motion_trace_models.py" --user-root "$U"
printf 'passed\n' > "$TASK/curation_complete"
echo "Recovered group2 with validated pinned model bytes; no live HEAD assertion"

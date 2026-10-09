#!/bin/bash
# Complete only failed array indices 5/6, without replacing their retained data.
#SBATCH -A naiss2026-3-127-cpu
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=24
#SBATCH --mem=96G
#SBATCH --time=12:00:00
#SBATCH --job-name=ks4-trace-recover

set -euo pipefail
U="/nobackup/proj/disk/dmclab/personal/${USER:?}"
T="$U/baseline_pilots/ks4_native_motion_trace_test_20261008"
D="$T/diagnostics_20261009"
PILOT="$U/baseline_pilots/ks4_followups_20261008_3526824"
BASE="$U/apptainer_cache/ghcr.io-allenneuraldynamics-aind-ephys-pipeline-base-1.4.0.img"
PATCHED="$U/containers/aind-ephys-curation_1.4.0_si4830.sif"
test "${SLURM_ARRAY_TASK_ID:?Submit array indices 5-6}" = 5 || test "$SLURM_ARRAY_TASK_ID" = 6
test -f "$BASE" && test -f "$PATCHED"
test "$(sha256sum "$PATCHED" | cut -d' ' -f1)" = \
    c5c211a7a5e50bdebd1cacbc20236a19d42c6555813ec7776ee07401b2f76993
test "$(sha256sum "$T/source/ks4_motion_trace_replay.py" | cut -d' ' -f1)" = \
    43eb4d0e78060e942df16d04680db86ddb9e01a1292910390b9f2b692e130efd
cd "$D"
sha256sum -c recovery_checksums.sha256
GROUP=$((SLURM_ARRAY_TASK_ID - 4))
REL=cohort08/20260719/vr2520260719_g0
NAME="block0_imec0.ap_recording1_group$GROUP"
TASK="$T/$REL/group$GROUP"
test -d "$TASK/corrected_binary" && test ! -e "$TASK/curation_complete"
BINDS="$U,$PILOT:$PILOT:ro,$U/raw_ecephys:$U/raw_ecephys:ro,$U/session_archives:$U/session_archives:ro"
export N_JOBS_EXT=24 OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1
export HF_HOME="$T/hf-cache"
export NUMBA_CACHE_DIR="$D/recovery_cache_${SLURM_ARRAY_TASK_ID}"
export MPLCONFIGDIR="$D/mpl_${SLURM_ARRAY_TASK_ID}"
mkdir -p "$NUMBA_CACHE_DIR" "$MPLCONFIGDIR"
apptainer exec -B "$BINDS" "$BASE" python -u "$D/ks4_motion_trace_recover.py" \
    --user-root "$U" --index "$SLURM_ARRAY_TASK_ID"
export N_JOBS_EXT=12
for ARM in uncorrected native_motion_interpolated; do
    test -f "$TASK/$ARM/postprocessing_complete" && test -f "$TASK/$ARM/curation_params.json"
    cd "$TASK/$ARM/curation/capsule/code"
    apptainer exec -B "$BINDS" "$PATCHED" python -u run_capsule.py --params "$(cat "$TASK/$ARM/curation_params.json")"
    test -f "$TASK/$ARM/curation/capsule/results/unit_labels_${NAME}.csv"
done
apptainer exec -B "$BINDS" "$PATCHED" python -u "$T/source/ks4_motion_trace_replay.py" check-models --user-root "$U"
printf 'passed\n' > "$TASK/curation_complete"
echo "Recovered downstream replay $REL group$GROUP (original sorting and corrected binary unchanged)"

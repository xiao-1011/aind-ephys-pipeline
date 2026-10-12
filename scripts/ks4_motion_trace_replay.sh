#!/bin/bash
#SBATCH -A naiss2026-3-127-cpu
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=24
#SBATCH --mem=96G
#SBATCH --time=12:00:00
#SBATCH --job-name=ks4-motion-trace
# Submit as --array=0-15%4 from a frozen copy of this script.
set -euo pipefail
U="/nobackup/proj/disk/dmclab/personal/${USER:?}"
SOURCE="${KS4_TRACE_SCRIPT:?Pass frozen Python script in KS4_TRACE_SCRIPT}"
ROOT="$U/baseline_pilots/ks4_native_motion_trace_test_20261008"
BASE="$U/apptainer_cache/ghcr.io-allenneuraldynamics-aind-ephys-pipeline-base-1.4.0.img"
PATCHED="$U/containers/aind-ephys-curation_1.4.0_si4830.sif"
test -f "$BASE" && test -f "$SOURCE" && test -f "$PATCHED"
test "$(sha256sum "$PATCHED" | cut -d' ' -f1)" = c5c211a7a5e50bdebd1cacbc20236a19d42c6555813ec7776ee07401b2f76993
test -n "${SLURM_ARRAY_TASK_ID:?Submit as an array}"
export N_JOBS_EXT=24 OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1
export HF_HOME="$ROOT/hf-cache"
export NUMBA_CACHE_DIR="$ROOT/cache/numba_${SLURM_ARRAY_TASK_ID}"
export MPLCONFIGDIR="$ROOT/cache/mpl_${SLURM_ARRAY_TASK_ID}"
mkdir -p "$NUMBA_CACHE_DIR" "$MPLCONFIGDIR"
PILOT="$U/baseline_pilots/ks4_followups_20261008_3526824"
BINDS="$U,$PILOT:$PILOT:ro,$U/raw_ecephys:$U/raw_ecephys:ro,$U/session_archives:$U/session_archives:ro"
apptainer exec -B "$BINDS" "$BASE" python -u "$SOURCE" run --user-root "$U" --index "$SLURM_ARRAY_TASK_ID"
# Obtain the new capsule directory from the test's own immutable provenance.
read -r REL GROUP NAME <<< "$(python3 - "$SLURM_ARRAY_TASK_ID" <<'PY'
import sys
sessions=('cohort07/20260501/vr2220260501_g0', 'cohort08/20260719/vr2520260719_g0', 'cohort09/20260921/vr2820260921_g0', 'cohort08/20260721/vr2320260721_g0')
i=int(sys.argv[1]);print(sessions[i//4],i%4,f'block0_imec0.ap_recording1_group{i%4}')
PY
)"
TASK="$ROOT/$REL/group$GROUP"
export N_JOBS_EXT=12
for ARM in uncorrected native_motion_interpolated; do
    test -f "$TASK/$ARM/postprocessing_complete" && test -f "$TASK/$ARM/curation_params.json"
    cd "$TASK/$ARM/curation/capsule/code"
    apptainer exec -B "$BINDS" "$PATCHED" python -u run_capsule.py --params "$(cat "$TASK/$ARM/curation_params.json")"
    test -f "$TASK/$ARM/curation/capsule/results/unit_labels_${NAME}.csv"
done
apptainer exec -B "$BINDS" "$PATCHED" python -u "$SOURCE" check-models --user-root "$U"
printf 'passed\n' > "$TASK/curation_complete"
echo "Verified downstream replay $REL group$GROUP (KS4 sorting unchanged)"

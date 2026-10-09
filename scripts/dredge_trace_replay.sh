#!/bin/bash
#SBATCH -A naiss2026-3-127-cpu
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=24
#SBATCH --mem=96G
#SBATCH --time=12:00:00
#SBATCH --job-name=dredge-trace-replay
# Submit a frozen copy as --array=0 (gate), then --array=1-19%4 if gate passes.
set -euo pipefail
U="/nobackup/proj/disk/dmclab/personal/${USER:?}"
ROOT="$U/baseline_pilots/dredge100_original_trace_20261009"
BASE="$U/apptainer_cache/ghcr.io-allenneuraldynamics-aind-ephys-pipeline-base-1.4.0.img"
PATCHED="$U/containers/aind-ephys-curation_1.4.0_si4830.sif"
INITIAL="$U/baseline_pilots/20261008_ks4_builtin64_vr1520260318_g0_ce4972d"
FOLLOWUPS="$U/baseline_pilots/ks4_followups_20261008_3526824"
PRIOR="$U/baseline_pilots/ks4_native_motion_trace_test_20261008"
test -n "${SLURM_ARRAY_TASK_ID:?Submit as array 0-19}"
test "$SLURM_ARRAY_TASK_ID" -ge 0 && test "$SLURM_ARRAY_TASK_ID" -le 19
test -f "$BASE" && test -f "$PATCHED"
test "$(sha256sum "$PATCHED" | cut -d' ' -f1)" = c5c211a7a5e50bdebd1cacbc20236a19d42c6555813ec7776ee07401b2f76993
cd "$ROOT"
sha256sum -c source_checksums.sha256
sha256sum -c stage_checksums.sha256
sha256sum -c replay_checksums.sha256
export HF_HOME="$ROOT/hf-cache"
export N_JOBS_EXT=24 OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1
export NUMBA_CACHE_DIR="$ROOT/cache/numba_${SLURM_ARRAY_TASK_ID}"
export MPLCONFIGDIR="$ROOT/cache/mpl_${SLURM_ARRAY_TASK_ID}"
mkdir -p "$NUMBA_CACHE_DIR" "$MPLCONFIGDIR"
BINDS="$U,$INITIAL:$INITIAL:ro,$FOLLOWUPS:$FOLLOWUPS:ro,$PRIOR:$PRIOR:ro,$ROOT/staged:$ROOT/staged:ro,$U/raw_ecephys:$U/raw_ecephys:ro,$U/session_archives:$U/session_archives:ro,$U/batch_runs:$U/batch_runs:ro"
apptainer exec -B "$BINDS" "$BASE" python -u "$ROOT/source/dredge_trace_replay.py" run --user-root "$U" --index "$SLURM_ARRAY_TASK_ID"
read -r REL GROUP NAME <<< "$(python3 - "$SLURM_ARRAY_TASK_ID" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, 'source')
from dredge_trace_probe import SESSIONS
i=int(sys.argv[1]);print(SESSIONS[i//4],i%4,f'block0_imec0.ap_recording1_group{i%4}')
PY
)"
TASK="$ROOT/replays/$REL/group$GROUP"
export N_JOBS_EXT=12
for ARM in original dredge_corrected; do
    test -f "$TASK/$ARM/postprocessing_complete" && test -f "$TASK/$ARM/curation_params.json"
    cd "$TASK/$ARM/curation/capsule/code"
    apptainer exec -B "$BINDS" "$PATCHED" python -u run_capsule.py --params "$(cat "$TASK/$ARM/curation_params.json")"
    test -f "$TASK/$ARM/curation/capsule/results/unit_labels_${NAME}.csv"
done
apptainer exec -B "$BINDS" "$PATCHED" python -u "$ROOT/source/dredge_trace_replay.py" check-models --user-root "$U"
printf 'passed\n' > "$TASK/curation_complete"
echo "Verified two DREDGE trace arms for $REL group$GROUP (sorting unchanged)"

#!/bin/bash
# Four follow-up KS4-only pilots, each independently archived and restore-verified.
# Submit from a pinned checkout with KS4_PILOT_REPO and KS4_PILOT_COMMIT exported.
#SBATCH -A naiss2026-3-127-cpu
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --time=3-00:00:00
#SBATCH --job-name=ks4-motion-pilots

set -euo pipefail
U="/nobackup/proj/disk/dmclab/personal/${USER:?}"
REPO="${KS4_PILOT_REPO:?Pass a pinned checkout in KS4_PILOT_REPO}"
test "$(git -C "$REPO" rev-parse HEAD)" = "${KS4_PILOT_COMMIT:?Pass its SHA in KS4_PILOT_COMMIT}"
test -z "$(git -C "$REPO" status --porcelain)"
P="$U/baseline_pilots/ks4_followups_20261008_${SLURM_JOB_ID:?Submit with sbatch}"
ARCHIVE_ROOT="$U/session_archives/ks4_motion_baseline_20261008"
BASELINE_REPORT="$U/baseline_pilots/20261008_ks4_builtin64_vr1520260318_g0_ce4972d/archive_report_6d38ae9.json"
BASE="$U/apptainer_cache/ghcr.io-allenneuraldynamics-aind-ephys-pipeline-base-1.4.0.img"
PATCHED="$U/containers/aind-ephys-curation_1.4.0_si4830.sif"
test -f "$BASE"
test ! -e "$P"
python3 - "$REPO" "$BASELINE_REPORT" "$U" <<'PY'
import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(sys.argv[1]) / "scripts"))
from archive_session import digest, require
from arrhenius_batch import validate_report
report = json.loads(Path(sys.argv[2]).read_text())
raw = Path(sys.argv[3]) / "raw_ecephys/cohort06/20260318/vr1520260318_g0"
archive = Path(sys.argv[3]) / "session_archives/ks4_motion_baseline_20261008/cohort06/20260318/vr1520260318_g0.tar"
require(report["raw"] == str(raw) and report["archive"] == str(archive), "Initial pilot report mismatch")
validate_report(report, {"raw": str(raw), "archive": str(archive)},
                digest(Path(sys.argv[1]) / "pipeline/active_params.json"))
print("Initial KS4-only pilot archive restore report and checksum verified", flush=True)
PY
mkdir -p "$P/source" "$P/logs" "$P/reports" "$P/jobs"
cp -a "$REPO/pipeline" "$REPO/scripts" "$P/source/"
printf '%s\n' "$KS4_PILOT_COMMIT" > "$P/source/source_commit.txt"
git -C "$REPO" diff HEAD > "$P/source/source_diff.patch"

# The recovered session alone needs the verified SI #4830 curation backport.
SPECIAL=cohort08/20260721/vr2320260721_g0
SPECIAL_SHA=c5c211a7a5e50bdebd1cacbc20236a19d42c6555813ec7776ee07401b2f76993
SESSIONS=(
    cohort07/20260501/vr2220260501_g0  # 76-80 channels
    cohort08/20260719/vr2520260719_g0  # 69-78 channels
    cohort09/20260921/vr2820260921_g0  # 95-96 channels
    "$SPECIAL"                         # exercise the known curation exception
)

for REL in "${SESSIONS[@]}"; do
    NAME="${REL##*/}"
    RAW="$U/raw_ecephys/$REL"
    RESULTS="$P/outputs/$REL"
    WORK="$P/work/$REL"
    ARCHIVE="$ARCHIVE_ROOT/$REL.tar"
    test -d "$RAW" && test ! -e "$RESULTS" && test ! -e "$WORK"
    test ! -e "$ARCHIVE" && test ! -e "$ARCHIVE.partial"
    PROVENANCE="$P/source"
    unset CURATION_SIF || true
    if [[ "$REL" == "$SPECIAL" ]]; then
        test "$(sha256sum "$PATCHED" | cut -d' ' -f1)" = "$SPECIAL_SHA"
        export CURATION_SIF="$PATCHED"
        PROVENANCE="$P/si4830_provenance"
        mkdir -p "$PROVENANCE"
        cp -a "$P/source/pipeline" "$PROVENANCE/"
        cp "$P/source/source_commit.txt" "$P/source/source_diff.patch" "$PROVENANCE/"
        cp "$PATCHED.sha256" "$PROVENANCE/si4830_image.sha256"
        cp "$PATCHED.provenance.json" "$PROVENANCE/si4830_image.provenance.json"
        cp "$U/session_log/si4830_verify_3513689/verification.json" "$PROVENANCE/si4830_verification.json"
    fi
    echo "$(date -Is) Starting $REL; source=$KS4_PILOT_COMMIT image=${CURATION_SIF:-stock}" | tee -a "$P/progress.log"
    export PIPELINE_PATH="$P/source" NXF_SESSION_WORK_ROOT="$P/work" ARRHENIUS_FRESH_RUN=1
    sbatch --wait --parsable --output="$P/logs/$NAME-pipeline-%j.out" \
        "$P/source/pipeline/arrhenius_submit.sh" "$RAW" "$RESULTS" | tee "$P/jobs/$NAME.pipeline.txt"
    PYTHONPATH="$P/source/scripts" python3 -c 'import sys; from archive_session import trace_check; trace_check(sys.argv[1])' "$RESULTS"
    apptainer exec -B "$U" "$BASE" python -u "$P/source/scripts/archive_session.py" pack \
        --results "$RESULTS" --raw "$RAW" --work "$WORK" --archive "$ARCHIVE" \
        --staging-root "$P/archive_staging" --report "$P/reports/$NAME.json" --provenance "$PROVENANCE"
    echo "$(date -Is) Verified $REL; pilot sources retained" | tee -a "$P/progress.log"
done

echo "KS4 pilot series complete: ${#SESSIONS[@]} sessions, no source cleanup"

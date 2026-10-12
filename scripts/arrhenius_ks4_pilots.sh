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
P="${KS4_PILOT_RESUME_ROOT:-$U/baseline_pilots/ks4_followups_20261008_${SLURM_JOB_ID:?Submit with sbatch}}"
ARCHIVE_ROOT="$U/session_archives/ks4_motion_baseline_20261008"
BASELINE_REPORT="$U/baseline_pilots/20261008_ks4_builtin64_vr1520260318_g0_ce4972d/archive_report_6d38ae9.json"
BASE="$U/apptainer_cache/ghcr.io-allenneuraldynamics-aind-ephys-pipeline-base-1.4.0.img"
PATCHED="$U/containers/aind-ephys-curation_1.4.0_si4830.sif"
test -f "$BASE"
if [[ -n "${KS4_PILOT_RESUME_ROOT:-}" ]]; then
    # Only the known failed controller is eligible for recovery. Its completed
    # Nextflow output must pass trace_check before we reuse it; never overwrite it.
    test "$P" = "$U/baseline_pilots/ks4_followups_20261008_3526824"
    test -d "$P/source" && test ! -L "$P"
    test "$(cat "$P/source/source_commit.txt")" = f7db4844c890c9fd5c00c952f06919585094c469
    diff -qr "$P/source/pipeline" "$REPO/pipeline"
    cmp "$P/source/scripts/archive_session.py" "$REPO/scripts/archive_session.py"
else
    test ! -e "$P"
fi
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
if [[ -z "${KS4_PILOT_RESUME_ROOT:-}" ]]; then
    mkdir -p "$P/source" "$P/logs" "$P/reports" "$P/jobs"
    cp -a "$REPO/pipeline" "$REPO/scripts" "$P/source/"
    printf '%s\n' "$KS4_PILOT_COMMIT" > "$P/source/source_commit.txt"
    git -C "$REPO" diff HEAD > "$P/source/source_diff.patch"
else
    printf '%s\n' "$KS4_PILOT_COMMIT" > "$P/controller_resume_commit.txt"
fi

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
    test -d "$RAW"
    REPORT="$P/reports/$NAME.json"
    if [[ -f "$REPORT" ]]; then
        python3 - "$P/source" "$REPORT" "$RAW" "$ARCHIVE" <<'PY'
import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(sys.argv[1]) / "scripts"))
from archive_session import digest
from arrhenius_batch import validate_report
report = json.loads(Path(sys.argv[2]).read_text())
validate_report(report, {"raw": sys.argv[3], "archive": sys.argv[4]},
                digest(Path(sys.argv[1]) / "pipeline/active_params.json"))
PY
        echo "$(date -Is) Already restore-verified $REL; pilot sources retained" | tee -a "$P/progress.log"
        continue
    fi
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
    if [[ -e "$RESULTS" || -e "$WORK" ]]; then
        test -d "$RESULTS" && test -d "$WORK"
        test -f "$P/jobs/$NAME.pipeline.txt"
        PYTHONPATH="$P/source/scripts" python3 -c 'import sys; from pathlib import Path; from archive_session import trace_check; trace_check(Path(sys.argv[1]))' "$RESULTS"
        echo "$(date -Is) Reusing completed pipeline for $REL; source=$(cat "$P/source/source_commit.txt")" | tee -a "$P/progress.log"
    else
        echo "$(date -Is) Starting $REL; source=$(cat "$P/source/source_commit.txt") image=${CURATION_SIF:-stock}" | tee -a "$P/progress.log"
        export PIPELINE_PATH="$P/source" NXF_SESSION_WORK_ROOT="$P/work" ARRHENIUS_FRESH_RUN=1
        sbatch --wait --parsable --output="$P/logs/$NAME-pipeline-%j.out" \
            "$P/source/pipeline/arrhenius_submit.sh" "$RAW" "$RESULTS" | tee "$P/jobs/$NAME.pipeline.txt"
        PYTHONPATH="$P/source/scripts" python3 -c 'import sys; from pathlib import Path; from archive_session import trace_check; trace_check(Path(sys.argv[1]))' "$RESULTS"
    fi
    apptainer exec -B "$U" "$BASE" python -u "$P/source/scripts/archive_session.py" pack \
        --results "$RESULTS" --raw "$RAW" --work "$WORK" --archive "$ARCHIVE" \
        --staging-root "$P/archive_staging" --report "$REPORT" --provenance "$PROVENANCE"
    echo "$(date -Is) Verified $REL; pilot sources retained" | tee -a "$P/progress.log"
done

echo "KS4 pilot series complete: ${#SESSIONS[@]} sessions, no source cleanup"

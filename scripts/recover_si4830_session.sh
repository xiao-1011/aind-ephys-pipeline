#!/bin/bash
# Resume only the retained skipped session, then build and restore-test its archive.
# Submit from the pushed repository root: sbatch scripts/recover_si4830_session.sh
#SBATCH -A naiss2026-3-127-cpu
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --time=12:00:00
#SBATCH --job-name=recover-si4830

set -euo pipefail
REPO="${SI4830_REPO:-${SLURM_SUBMIT_DIR:?Submit from the pipeline repository root}}"
U="/nobackup/proj/disk/dmclab/personal/$USER"
B="$U/batch_runs/20261006_180017"
REL="cohort08/20260721/vr2320260721_g0"
SIF="$U/containers/aind-ephys-curation_1.4.0_si4830.sif"
BASE="$U/apptainer_cache/ghcr.io-allenneuraldynamics-aind-ephys-pipeline-base-1.4.0.img"
RAW="$U/raw_ecephys/$REL"
WORK="$B/work/$REL"
RESULTS="$B/outputs/$REL"
ARCHIVE="$U/session_archives/$REL.tar"
RECOVERY="$B/recovery_si4830_${SLURM_JOB_ID:?Submit with sbatch}"
VERIFICATION="$U/session_log/si4830_verify_3513689/verification.json"

[[ -d "$WORK" && -d "$RAW" && -d "$RESULTS" && ! -e "$ARCHIVE" && ! -e "$ARCHIVE.partial" && ! -e "$RECOVERY" ]]
[[ -f "$SIF" && -f "$BASE" && -f "$VERIFICATION" ]]
sha256sum --check "$SIF.sha256"
python3 - "$B" "$REL" "$VERIFICATION" <<'PY'
import hashlib, json, pathlib, sys
batch, rel, verification = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
manifest = json.loads((batch/'manifest.json').read_text())
row, = [r for r in manifest['sessions'] if r['relative'] == rel]
assert manifest['status'] == 'complete_with_skips' and row['status'] == 'skipped_failed'
assert hashlib.sha256((batch/'snapshot/pipeline/active_params.json').read_bytes()).hexdigest() == manifest['params_sha256']
report = json.loads(verification.read_text())
assert report['status'] == 'passed' and report['reference_predictions_identical'] and report['source_analyzers_unchanged']
PY

# Prevent another batch or recovery from sharing this archive namespace.
exec 9>"$U/session_archives/.batch.lock"
flock -n 9
mkdir -p "$RECOVERY"
trap 'rc=$?; if ((rc != 0)); then echo "RECOVERY FAILED (exit $rc): sources untouched; inspect $RECOVERY and session logs"; fi' EXIT
cp -a "$B/snapshot/pipeline" "$RECOVERY/pipeline"
cp "$B/snapshot/source_commit.txt" "$RECOVERY/source_commit.txt"
cp "$SIF.provenance.json" "$RECOVERY/si4830_image.provenance.json"
cp "$SIF.sha256" "$RECOVERY/si4830_image.sha256"
cp "$VERIFICATION" "$RECOVERY/si4830_verification.json"

python3 - "$RECOVERY" "$B" "$REPO" "$SIF" "$REL" <<'PY'
import difflib, hashlib, json, pathlib, subprocess, sys
recovery, batch, repo, image, rel = map(pathlib.Path, sys.argv[1:])
original = batch/'snapshot/pipeline/nextflow_arrhenius.config'
config = recovery/'pipeline/nextflow_arrhenius.config'
before = original.read_text()
anchor = '    withName: curation {\n'
assert before.count(anchor) == 1 and 'CURATION_SIF' not in before
after = before.replace(anchor, anchor + f"        container = '{image}'\n")
config.write_text(after)
submit = recovery/'pipeline/arrhenius_submit.sh'
source = submit.read_text()
old = '-C "$PIPELINE_PATH/pipeline/nextflow_arrhenius.config"'
assert source.count(old) == 1
submit.write_text(source.replace(old, '-C "$ARRHENIUS_RECOVERY_CONFIG"'))
(recovery/'source_diff.patch').write_text(''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
    fromfile='snapshot/pipeline/nextflow_arrhenius.config', tofile='recovery/pipeline/nextflow_arrhenius.config')))
def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(8*1024*1024), b''): h.update(block)
    return h.hexdigest()
report = dict(session=str(rel), original_batch=str(batch),
                  original_pipeline_commit=(batch/'snapshot/source_commit.txt').read_text().strip(),
                  recovery_script_commit=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'], text=True).strip(),
                  original_config_sha256=digest(original), recovery_config_sha256=digest(config),
                  params_sha256=digest(batch/'snapshot/pipeline/active_params.json'),
                  curation_image=str(image), curation_image_sha256=digest(image),
                  verification_report=str(recovery/'si4830_verification.json'))
(recovery/'si4830_recovery.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report, indent=2), flush=True)
PY

export PIPELINE_PATH="$B/snapshot"
export NXF_SESSION_WORK_ROOT="$B/work"
export ARRHENIUS_RECOVERY_CONFIG="$RECOVERY/pipeline/nextflow_arrhenius.config"
echo "Resuming only $REL, config $ARRHENIUS_RECOVERY_CONFIG"
sbatch --wait --parsable --output="$RECOVERY/pipeline-%j.out" \
    --export=ALL,PIPELINE_PATH,NXF_SESSION_WORK_ROOT,ARRHENIUS_RECOVERY_CONFIG \
    "$RECOVERY/pipeline/arrhenius_submit.sh" "$RAW" "$RESULTS" | tee "$RECOVERY/pipeline_job.txt"

echo "Full pipeline finished. Packing and restore-testing the archive; no cleanup will occur."
apptainer exec -B "$U" "$BASE" python -u "$REPO/scripts/archive_session.py" pack \
    --results "$RESULTS" --raw "$RAW" --work "$WORK" --archive "$ARCHIVE" \
    --staging-root "$B/archive_staging" --report "$RECOVERY/archive_report.json" \
    --provenance "$RECOVERY"
echo "RECOVERY ARCHIVE VERIFIED: $RECOVERY/archive_report.json"
echo "Batch manifest and retained session source directories intentionally unchanged."

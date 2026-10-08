#!/bin/bash
# Submit from the pushed repository: sbatch scripts/build_curation_si4830.sh [output.sif]
#SBATCH -A naiss2026-3-127-cpu
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=24G
#SBATCH --time=01:00:00
#SBATCH --job-name=build-curation-si4830

set -euo pipefail
# Slurm executes a spool copy; submission from the repository root is required.
REPO="${SI4830_REPO:-${SLURM_SUBMIT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}}"
USER_DIR="/nobackup/proj/disk/dmclab/personal/$USER"
BASE="${SI4830_BASE_IMAGE:-$USER_DIR/apptainer_cache/ghcr.io-allenneuraldynamics-aind-ephys-pipeline-base-1.4.0.img}"
SIF="${1:-$USER_DIR/containers/aind-ephys-curation_1.4.0_si4830.sif}"
[[ "$(uname -m)" == x86_64 && -f "$BASE" && -f "$REPO/environment/curation_si4830.def" ]]
[[ ! -e "$SIF" && ! -e "$SIF.partial" && ! -e "$SIF.sha256" && ! -e "$SIF.provenance.json" ]]
git -C "$REPO" diff --exit-code HEAD -- environment scripts tests/test_si4830.py
mkdir -p "$(dirname "$SIF")" "$USER_DIR/apptainer_tmp"
BUILD="$(mktemp -d "$USER_DIR/apptainer_tmp/si4830-build-XXXXXX")"
export APPTAINER_TMPDIR="$BUILD/tmp"
export APPTAINER_CACHEDIR="$USER_DIR/apptainer_cache/.apptainer"
mkdir -p "$APPTAINER_TMPDIR" "$APPTAINER_CACHEDIR"
trap 'rc=$?; if [[ $rc == 0 ]]; then rm -rf -- "$BUILD"; else echo "Build failed; retained $BUILD and any partial image"; fi' EXIT

python3 - "$BASE" "$REPO" "$BUILD/manifest.json" <<'PY'
from datetime import datetime, timezone
import hashlib, json, pathlib, subprocess, sys
base, repo, output = map(pathlib.Path, sys.argv[1:])
h = hashlib.sha256()
with base.open('rb') as f:
    for block in iter(lambda: f.read(8 * 1024 * 1024), b''):
        h.update(block)
report = dict(base_image=str(base.resolve()), base_image_sha256=h.hexdigest(),
              pipeline_commit=subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip(),
              built_at=datetime.now(timezone.utc).isoformat())
output.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report), flush=True)
PY

apptainer build --build-arg "base_image=$BASE" --build-arg "source_dir=$REPO" \
    --build-arg "build_manifest=$BUILD/manifest.json" "$SIF.partial" "$REPO/environment/curation_si4830.def"
# A fresh runtime process also tests that the modified module/bytecode is loaded.
apptainer exec --env OPENBLAS_NUM_THREADS=1,OMP_NUM_THREADS=1 "$SIF.partial" /opt/conda/bin/python /opt/si4830/test_si4830.py -v
apptainer exec "$SIF.partial" cat /opt/si4830/provenance.json > "$SIF.provenance.json.partial"
mv -- "$SIF.partial" "$SIF"
mv -- "$SIF.provenance.json.partial" "$SIF.provenance.json"
sha256sum "$SIF" > "$SIF.sha256"
echo "Patched image ready: $SIF"

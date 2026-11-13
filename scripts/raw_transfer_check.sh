#!/bin/bash
# Verify a copied raw cohort against its source manifest (see raw_transfer_check.py).
# Submit from the pipeline repository root:
#   sbatch scripts/raw_transfer_check.sh MANIFEST.json /nobackup/.../raw_ecephys/cohort10
# Read-only on the data; the report is written next to the manifest.
#SBATCH -A naiss2026-3-127-cpu
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=8G
#SBATCH --time=06:00:00
#SBATCH --job-name=raw-transfer-check
#SBATCH --output=raw-transfer-check-%j.out

set -euo pipefail
REPO="${SLURM_SUBMIT_DIR:?Submit from the pipeline repository root}"
MANIFEST="${1:?Usage: sbatch scripts/raw_transfer_check.sh MANIFEST DEST}"
DEST="${2:?Usage: sbatch scripts/raw_transfer_check.sh MANIFEST DEST}"
python3 -u "$REPO/scripts/raw_transfer_check.py" verify "$MANIFEST" "$DEST" --workers "${SLURM_CPUS_PER_TASK:-8}"

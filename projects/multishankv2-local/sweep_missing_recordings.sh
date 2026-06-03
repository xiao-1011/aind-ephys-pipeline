#!/usr/bin/env bash
# One-off: search every plausible storage location for the "missing" recordings
# from the experimenter log, and report where they're actually found.
#
# Sweeps:
#   - /mnt/dmclab/Anil/        (KI server, my tree)
#   - /mnt/dmclab/Joana/       (KI server, shared Joana tree)
#   - /mnt/dmclab/00_Backups/, /mnt/dmclab/00_Archive/
#   - /media/data/             (local HDD)
#   - /home/anil/Documents/    (local SSD)
#   - /mnt/dardel/             (Dardel klemming, sshfs-mounted)
#   - dardel:/cfs/...          (Dardel via ssh, in case sshfs isn't current)
#
# Matching: any `.ap.meta` whose path contains BOTH the date and animal_id
# from a missing log entry (substring match — handles sids like
# `2026-04-19_997287_1027553_opto_g0` that have two animals in the name).
#
# Usage:
#   bash sweep_missing_recordings.sh

set -uo pipefail

LOG_FILE="/mnt/dmclab/Anil/DATA_NPX/neuropixels_recording_log.xlsm - Recordings.csv"
MISSING_CSV="/mnt/dmclab/Anil/DATA_NPX/MISSING_RECORDINGS.csv"
OUT="/mnt/dmclab/Anil/DATA_NPX/SWEEP_RESULTS.csv"
OUT_TMP="/tmp/_sweep.$$"

if [ ! -f "${MISSING_CSV}" ]; then
    echo "Run multishankv2_status.sh first to produce MISSING_RECORDINGS.csv" >&2
    exit 1
fi

# Extract (date, animal) pairs for entries marked MISSING
mapfile -t MISSING_ROWS < <(awk -F, '$5 == "MISSING" {print $1 "|" $2}' "${MISSING_CSV}")
echo "Missing entries to look for: ${#MISSING_ROWS[@]}" >&2

# Collect all .ap.meta paths. Output: "<label>\t<path>"
collect_metas() {
    local label=$1
    local root=$2
    if [ ! -d "${root}" ]; then return; fi
    echo "[scan] ${label}: ${root}" >&2
    find "${root}" -maxdepth 6 -name "*.ap.meta" 2>/dev/null \
        | awk -v lbl="${label}" '{print lbl "\t" $0}'
}

collect_dardel_metas() {
    local label=$1
    local root=$2
    echo "[scan-ssh] ${label}: ${root}" >&2
    ssh dardel "find ${root} -maxdepth 6 -name '*.ap.meta' 2>/dev/null" \
        | awk -v lbl="${label}" '{print lbl "\t" $0}'
}

ALL_METAS=$(mktemp)
trap "rm -f ${ALL_METAS}" EXIT

{
    collect_metas KI_Anil       /mnt/dmclab/Anil
    collect_metas KI_Joana      /mnt/dmclab/Joana
    collect_metas KI_Backups    /mnt/dmclab/00_Backups
    collect_metas KI_Archive    /mnt/dmclab/00_Archive
    collect_metas Local_HDD     /media/data
    collect_metas Local_SSD     /home/anil/Documents
    # Optional dardel sweep — slow over ssh; uncomment if needed
    collect_dardel_metas Dardel /cfs/klemming/projects/supr/dmclab
} > "${ALL_METAS}" 2>/dev/null

echo "Total .ap.meta files seen: $(wc -l < ${ALL_METAS})" >&2

# For each missing (date, animal), grep ALL_METAS for paths containing both
{
    echo "log_date,log_animal,locations_found,found_paths"
    for row in "${MISSING_ROWS[@]}"; do
        d="${row%%|*}"
        a_raw="${row##*|}"
        # Extract numeric animal IDs (handles annotated values like '1021200 (files named 1021202)')
        mapfile -t animal_ids < <(echo "${a_raw}" | grep -oE '[0-9]{6,7}' | sort -u)
        if [ "${#animal_ids[@]}" -eq 0 ]; then
            continue
        fi
        # Build regex: line contains date AND any animal_id
        animal_alt=$(IFS='|'; echo "${animal_ids[*]}")
        hits=$(grep -E "${d}.*(${animal_alt})|(${animal_alt}).*${d}" "${ALL_METAS}" || true)
        if [ -z "${hits}" ]; then
            echo "${d},${a_raw},NONE,"
        else
            # Group by location label, dedupe directories
            locations=$(echo "${hits}" | awk -F'\t' '{print $1}' | sort -u | paste -sd';' -)
            paths=$(echo "${hits}" | awk -F'\t' '{print $2}' | xargs -n1 dirname | xargs -n1 dirname | sort -u | paste -sd';' -)
            # CSV-safe
            a_clean=$(echo "${a_raw}" | sed 's/,/;/g')
            echo "${d},${a_clean},${locations},${paths}"
        fi
    done
} > "${OUT_TMP}"

cat "${OUT_TMP}" > "${OUT}"
rm -f "${OUT_TMP}"
echo "Wrote: ${OUT}"
echo
echo "=== Results ==="
column -s, -t < "${OUT}"

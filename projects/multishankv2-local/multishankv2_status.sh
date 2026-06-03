#!/usr/bin/env bash
# multishankv2 master status — what's where, across raw + local + KI + Dardel.
#
# Scans:
#   - /mnt/dmclab/Anil/DATA_NPX/        (raw, KI NAS)
#   - /media/data/ephys-pipeline-output/ (local workstation, multishankv2-local)
#   - /mnt/dmclab/Anil/ephys-pipeline-output/<batch>/results/ (KI processed)
#   - dardel:/cfs/.../ephys-pipeline-output/multishankv2*/results/ (Dardel)
#
# Output: per-session row with shank-level completeness in each location.
# Re-runnable any time.
#
# Usage:
#   bash multishankv2_status.sh                  # write markdown to default
#   bash multishankv2_status.sh /tmp/foo.md      # custom path
#   bash multishankv2_status.sh -                # stdout

set -euo pipefail

RAW_BASE="/mnt/dmclab/Anil/DATA_NPX"
LOCAL_RESULTS="/media/data/ephys-pipeline-output"
KI_RESULTS_BASE="/mnt/dmclab/Anil/ephys-pipeline-output"
DARDEL_RESULTS_BASE="/cfs/klemming/projects/supr/dmclab/ephys-pipeline-output"
DEFAULT_OUT="${RAW_BASE}/SESSIONS_STATUS.csv"

OUT="${1:-${DEFAULT_OUT}}"

echo "[scan] raw recordings ..." >&2
mapfile -t METAS < <(find "${RAW_BASE}" -maxdepth 5 -name "*.ap.meta" 2>/dev/null | sort)

# Pull Dardel processed-sessions list with shank-level adv_curate count in one ssh round-trip.
# Output format per line: <sid> <batch> <shank_count>
echo "[scan] dardel multishankv2 batches ..." >&2
DARDEL_DATA=$(ssh dardel "
for b in ${DARDEL_RESULTS_BASE}/multishankv2*/results; do
    [ -d \$b ] || continue
    bname=\$(basename \$(dirname \$b))
    for s in \$b/*/; do
        sid=\$(basename \$s)
        [ \"\$sid\" = nextflow ] && continue
        for imec in \$s/\${sid}_imec*; do
            [ -d \$imec ] || continue
            count=\$(ls \$imec/shank*/advanced_curation_kilosort4.json 2>/dev/null | wc -l)
            echo \"\$sid \$bname \$count\"
        done
    done
done
" 2>/dev/null)

declare -A DARDEL_COUNT DARDEL_BATCH
while read -r sid batch count; do
    [ -z "${sid:-}" ] && continue
    DARDEL_COUNT[$sid]=$count
    DARDEL_BATCH[$sid]=$batch
done <<< "$DARDEL_DATA"

count_local() {
    local sid=$1
    local imec0="${LOCAL_RESULTS}/${sid}/results/${sid}/${sid}_imec0"
    [ -d "${imec0}" ] || { echo 0; return; }
    # Use shopt nullglob-style expansion to avoid ls returning non-zero on empty
    local matches=("${imec0}"/shank*/advanced_curation_kilosort4.json)
    local n=0
    for f in "${matches[@]}"; do
        [ -f "${f}" ] && n=$((n+1))
    done
    echo "${n}"
}
count_ki() {
    local sid=$1
    for batch in "${KI_RESULTS_BASE}"/*/results/"${sid}"; do
        [ -d "${batch}" ] || continue
        local imec0="${batch}/${sid}_imec0"
        [ -d "${imec0}" ] || continue
        local matches=("${imec0}"/shank*/advanced_curation_kilosort4.json)
        local n=0
        for f in "${matches[@]}"; do
            [ -f "${f}" ] && n=$((n+1))
        done
        if [ "${n}" -gt 0 ]; then
            echo "${n}"
            return
        fi
    done
    echo 0
}
ki_batch_for() {
    local sid=$1
    for batch in "${KI_RESULTS_BASE}"/*/results/"${sid}"; do
        [ -d "${batch}" ] || continue
        echo "$(basename "$(dirname "$(dirname "${batch}")")")"
        return
    done
    echo ""
}

render_mark() {
    # 0 -> ✗   N -> N/4   4 -> ✓
    case "$1" in
        0) echo "✗" ;;
        4) echo "✓" ;;
        "") echo "—" ;;
        *) echo "$1/4" ;;
    esac
}

OUT_TMP="/tmp/_msv2_status.$$"
declare -a FOUND_SIDS=()
{
    echo "session,raw_location,raw_size,raw_size_gb,duration_min,local_shanks,ki_shanks,dardel_shanks,ki_batch,dardel_batch,status,notes"

    total=0; done_anywhere=0; only_dardel=0; partial=0; pending=0; skipped=0
    for meta in "${METAS[@]}"; do
        imec_dir=$(dirname "${meta}")
        imec_base=$(basename "${imec_dir}")
        sid="${imec_base%_imec*}"
        case "${sid}" in
            ????-??-??_*_g[0-9]*) ;;
            *) continue ;;
        esac

        meta_size=$(stat -c %s "${meta}" 2>/dev/null || echo 0)
        if [ "${meta_size}" -lt 1000 ]; then
            skipped=$((skipped+1))
            continue
        fi

        total=$((total+1))
        bin="${meta%.meta}.bin"
        # Force C locale so du uses "." not "," (avoids breaking CSV parsing)
        sz=$(LC_ALL=C du -shL "${bin}" 2>/dev/null | cut -f1)
        [ -z "${sz}" ] && sz="?"
        # Numeric size in GB (for sum/sort in spreadsheets)
        sz_bytes=$(LC_ALL=C stat -c %s "${bin}" 2>/dev/null || echo 0)
        sz_gb=$(awk "BEGIN{printf \"%.1f\", ${sz_bytes} / 1024 / 1024 / 1024}")

        # Compact raw_location label: "DATA_NPX root", "batchN", "<animal>/<date>/recording"
        rel_path="${imec_dir#${RAW_BASE}/}"
        case "${rel_path}" in
            batch*/*) raw_loc=$(echo "${rel_path}" | cut -d/ -f1) ;;
            */*/recording/*) raw_loc=$(echo "${rel_path}" | cut -d/ -f1-3) ;;
            ${sid}/${imec_base}) raw_loc="DATA_NPX root" ;;
            *) raw_loc="${rel_path%/*}" ;;
        esac

        dur_sec=$(grep -m1 fileTimeSecs "${meta}" 2>/dev/null | cut -d= -f2)
        if [ -n "${dur_sec}" ]; then
            dur_min=$(awk "BEGIN{printf \"%.0f\", ${dur_sec} / 60}")
        else
            dur_min=""
        fi
        notes=""
        if [ -n "${dur_sec}" ] && [ "$(awk "BEGIN{print (${dur_sec} < 600)}")" = "1" ]; then
            notes="short (likely test)"
        fi

        local_c=$(count_local "${sid}")
        ki_c=$(count_ki "${sid}")
        ki_batch=$(ki_batch_for "${sid}")
        dardel_c=${DARDEL_COUNT[$sid]:-0}
        dardel_batch=${DARDEL_BATCH[$sid]:-}

        # Status classification (single canonical label per row, easy to filter)
        if [ "${ki_c}" = 4 ] || [ "${local_c}" = 4 ] || [ "${dardel_c}" = 4 ]; then
            done_anywhere=$((done_anywhere+1))
            if [ "${ki_c}" = 4 ]; then
                status="on_ki"
            elif [ "${local_c}" = 4 ] && [ "${dardel_c}" = 4 ]; then
                status="on_local_and_dardel"
            elif [ "${local_c}" = 4 ]; then
                status="on_local_only"
                [ -z "${notes}" ] && notes="local copy — should push to KI"
            elif [ "${dardel_c}" = 4 ]; then
                status="on_dardel_only"
                only_dardel=$((only_dardel+1))
                [ -z "${notes}" ] && notes="on Dardel only — needs sync to KI"
            fi
        elif [ "${local_c}" != 0 ] || [ "${ki_c}" != 0 ] || [ "${dardel_c}" != 0 ]; then
            status="partial"
            partial=$((partial+1))
            [ -z "${notes}" ] && notes="partial (missing some shanks)"
        else
            status="pending"
            pending=$((pending+1))
            [ -z "${notes}" ] && notes="not yet processed"
        fi

        # Escape any commas in notes
        notes_clean=$(echo "${notes}" | sed 's/,/;/g')
        echo "${sid},${raw_loc},${sz},${sz_gb},${dur_min},${local_c},${ki_c},${dardel_c},${ki_batch:-},${dardel_batch:-},${status},${notes_clean}"
    done

    # Trailing summary as comment-style lines (Excel ignores; humans can read)
    echo "# Generated $(date '+%Y-%m-%d %H:%M')"
    echo "# Summary: ${total} valid sessions; ${done_anywhere} fully sorted somewhere; ${only_dardel} only on Dardel (needs KI sync); ${partial} partial; ${pending} pending; ${skipped} skipped (0-byte/corrupt meta)"
    echo "# Status values: on_ki | on_local_and_dardel | on_local_only | on_dardel_only | partial | pending"
    echo "# Shanks columns: 0..4 (count of shanks with advanced_curation_kilosort4.json)"
    echo "# Paths: raw=${RAW_BASE}/; local=${LOCAL_RESULTS}/<sid>/results/; ki=${KI_RESULTS_BASE}/<batch>/results/<sid>/; dardel=${DARDEL_RESULTS_BASE}/<batch>/results/<sid>/"
} > "${OUT_TMP}"

if [ "${OUT}" = "-" ]; then
    cat "${OUT_TMP}"
    rm -f "${OUT_TMP}"
else
    # CIFS has cache coherency quirks where mv-over-existing fails.
    # Open-and-truncate via cat avoids creating a new inode.
    cat "${OUT_TMP}" > "${OUT}"
    rm -f "${OUT_TMP}"
    echo "Wrote: ${OUT}"
fi

# ── MISSING_RECORDINGS: cross-reference experimenter log with disk ───────────
LOG_FILE="${RAW_BASE}/neuropixels_recording_log.xlsm - Recordings.csv"
MISSING_OUT="${RAW_BASE}/MISSING_RECORDINGS.csv"
if [ -f "${LOG_FILE}" ]; then
    echo "[scan] cross-referencing experimenter log ..." >&2
    # Re-read the SIDs from the CSV we just wrote (subshell-safe)
    mapfile -t FOUND_SIDS < <(awk -F, 'NR>1 && $1 !~ /^#/ {print $1}' "${OUT}")
    {
        echo "log_date,log_animal,log_purpose,disk_sessions,status,note"
        while IFS= read -r line; do
            # Skip header
            [ "${line%%,*}" = "Date" ] && continue
            # First three CSV fields (Date, Animal ID, Purpose)
            log_date=$(echo "${line}" | awk -F, '{print $1}')
            log_animal_raw=$(echo "${line}" | awk -F, '{print $2}')
            log_purpose=$(echo "${line}" | awk -F, '{print $3}')
            [ -z "${log_date}" ] && continue
            # Extract numeric animal IDs (handles "1021200 (files named 1021202)" by taking
            # any 6-7 digit sequences in the field)
            mapfile -t animal_ids < <(echo "${log_animal_raw}" | grep -oE '[0-9]{6,7}' | sort -u)
            [ "${#animal_ids[@]}" -eq 0 ] && continue

            # Find any disk sid containing this date AND any animal_id (substring
            # match — handles sids like 2026-04-19_997287_1027553_opto_g0 where
            # multiple animals appear in the name, or where the outer dir's date
            # differs from the inner imec's date)
            matches=""
            for sid in "${FOUND_SIDS[@]}"; do
                [[ "${sid}" == *"${log_date}"* ]] || continue
                for a in "${animal_ids[@]}"; do
                    if [[ "${sid}" == *"${a}"* ]]; then
                        [ -n "${matches}" ] && matches+=";"
                        matches+="${sid}"
                        break
                    fi
                done
            done

            # Dedup matches (sed instead of grep -v since grep -v returns 1 on no matches → pipefail)
            matches=$(echo "${matches}" | tr ';' '\n' | sort -u | sed '/^$/d' | paste -sd';' -)

            if [ -n "${matches}" ]; then
                status="found"
                note=""
            else
                status="MISSING"
                note="logged but no raw on disk under ${RAW_BASE}"
            fi

            # CSV-safe
            log_purpose_clean=$(echo "${log_purpose}" | sed 's/,/;/g')
            note_clean=$(echo "${note}" | sed 's/,/;/g')
            log_animal_clean=$(echo "${log_animal_raw}" | sed 's/,/;/g')

            echo "${log_date},${log_animal_clean},${log_purpose_clean},${matches},${status},${note_clean}"
        done < "${LOG_FILE}"
    } > "${MISSING_OUT}.tmp"
    cat "${MISSING_OUT}.tmp" > "${MISSING_OUT}"
    rm -f "${MISSING_OUT}.tmp"
    echo "Wrote: ${MISSING_OUT}"
    n_missing=$(awk -F, '$5 == "MISSING"' "${MISSING_OUT}" | wc -l)
    n_found=$(awk -F, '$5 == "found"' "${MISSING_OUT}" | wc -l)
    echo "  ${n_found} log entries match disk, ${n_missing} have no disk match."
fi

echo
echo "Preview (column-aligned):"
column -s, -t < "${OUT}" | head -50

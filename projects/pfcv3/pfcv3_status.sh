#!/usr/bin/env bash
# pfcv3 / PFC master status — what's where for the PFC-Str behavior project.
#
# Scans:
#   KI raw:       /mnt/dmclab/Joana/PFC-Str_behavior_project/Recordings/Raw_data/<animal>/<session>
#   Dardel raw:   /cfs/.../Joana/Raw_data/<animal>/<session>
#   KI processed: /mnt/dmclab/Joana/PFC-Str_behavior_project/Analysis/ephys-pipeline-output/results/<session>
#   Dardel proc:  /cfs/.../ephys-pipeline-output/pfcv*/results/<session>
#
# Probes per session: imec0 and (usually) imec1 — single-shank NPx 1.0, so
# completeness = number of probes with advanced_curation_kilosort4.json (0–2).
#
# Output CSV: /mnt/dmclab/Joana/PFC-Str_behavior_project/Analysis/PFC_STATUS.csv
#
# Usage:
#   bash pfcv3_status.sh             # write CSV to default
#   bash pfcv3_status.sh /tmp/x.csv  # custom path
#   bash pfcv3_status.sh -           # stdout

set -uo pipefail

KI_RAW="/mnt/dmclab/Joana/PFC-Str_behavior_project/Recordings/Raw_data"
KI_PROC="/mnt/dmclab/Joana/PFC-Str_behavior_project/Analysis/ephys-pipeline-output/results"
DARDEL_RAW="/cfs/klemming/projects/supr/dmclab/Joana/Raw_data"
DARDEL_PROC_BASE="/cfs/klemming/projects/supr/dmclab/ephys-pipeline-output"
DEFAULT_OUT="/mnt/dmclab/Joana/PFC-Str_behavior_project/Analysis/PFC_STATUS.csv"

OUT="${1:-${DEFAULT_OUT}}"

echo "[scan] KI raw recordings ..." >&2
# Find session dirs (depth 2 below KI_RAW: animal/session)
mapfile -t KI_SESSIONS < <(find "${KI_RAW}" -mindepth 2 -maxdepth 2 -type d -name '*_g[0-9]*' \
                                  ! -name '*_imec*' 2>/dev/null | sort)

echo "  found ${#KI_SESSIONS[@]} sessions in KI raw" >&2

# Pull Dardel state in one ssh round-trip
echo "[scan] Dardel raw + processed ..." >&2
DARDEL_DATA=$(ssh dardel "
# Raw
for animal_dir in ${DARDEL_RAW}/*/; do
    [ -d \$animal_dir ] || continue
    for sess in \$animal_dir/*_g[0-9]*; do
        [ -d \$sess ] || continue
        sname=\$(basename \$sess)
        case \$sname in *_imec*) continue ;; esac
        echo \"RAW \$sname\"
    done
done
# Processed (any pfcv* batch)
for batch in ${DARDEL_PROC_BASE}/pfcv*/results; do
    [ -d \$batch ] || continue
    bname=\$(basename \$(dirname \$batch))
    for s in \$batch/*/; do
        sid=\$(basename \$s)
        [ \"\$sid\" = nextflow ] && continue
        n_probes=0
        for imec in \$s/\${sid}_imec*; do
            [ -d \$imec ] || continue
            if [ -f \$imec/advanced_curation_kilosort4.json ]; then
                n_probes=\$((n_probes+1))
            fi
        done
        echo \"PROC \$sid \$bname \$n_probes\"
    done
done
" 2>/dev/null)

declare -A DARDEL_RAW_HAS DARDEL_PROC_COUNT DARDEL_PROC_BATCH
while IFS= read -r line; do
    [ -z "${line}" ] && continue
    kind=$(echo "${line}" | awk '{print $1}')
    if [ "${kind}" = "RAW" ]; then
        sid=$(echo "${line}" | awk '{print $2}')
        DARDEL_RAW_HAS[$sid]=1
    elif [ "${kind}" = "PROC" ]; then
        sid=$(echo "${line}" | awk '{print $2}')
        batch=$(echo "${line}" | awk '{print $3}')
        n=$(echo "${line}" | awk '{print $4}')
        # Prefer the batch with more probes processed
        prev=${DARDEL_PROC_COUNT[$sid]:-0}
        if [ "${n}" -gt "${prev}" ]; then
            DARDEL_PROC_COUNT[$sid]=$n
            DARDEL_PROC_BATCH[$sid]=$batch
        fi
    fi
done <<< "$DARDEL_DATA"

count_ki_processed() {
    # echo "<count> <expected>" where expected = number of probe dirs that exist on KI raw
    local sid=$1
    local sess_dir="${KI_PROC}/${sid}"
    local n=0
    if [ -d "${sess_dir}" ]; then
        for imec in "${sess_dir}"/${sid}_imec*; do
            [ -d "${imec}" ] || continue
            [ -f "${imec}/advanced_curation_kilosort4.json" ] && n=$((n+1))
        done
    fi
    echo "${n}"
}

OUT_TMP="/tmp/_pfc_status.$$"
{
    echo "session,animal,raw_size,raw_size_gb,n_probes,raw_on_ki,raw_on_dardel,ki_processed,dardel_processed,ki_batch,dardel_batch,status,notes"

    total=0; on_ki=0; on_dardel_only=0; partial=0; pending=0
    for sess_dir in "${KI_SESSIONS[@]}"; do
        sid=$(basename "${sess_dir}")
        animal_dir=$(dirname "${sess_dir}")
        animal=$(basename "${animal_dir}")

        # Probe count and total raw size from KI raw
        mapfile -t imec_dirs < <(find "${sess_dir}" -mindepth 1 -maxdepth 1 -type d -name "*_imec*" 2>/dev/null)
        n_probes=${#imec_dirs[@]}
        if [ "${n_probes}" -eq 0 ]; then continue; fi
        total=$((total+1))

        # Sum binary sizes
        total_bytes=0
        for imec in "${imec_dirs[@]}"; do
            for bin in "${imec}"/*.ap.bin; do
                [ -f "${bin}" ] || continue
                b=$(LC_ALL=C stat -c %s "${bin}" 2>/dev/null || echo 0)
                total_bytes=$((total_bytes + b))
            done
        done
        sz_gb=$(awk "BEGIN{printf \"%.1f\", ${total_bytes} / 1024 / 1024 / 1024}")
        sz=$(awk "BEGIN{
            v=${total_bytes}/1024/1024/1024
            if (v >= 1024) printf \"%.1fT\", v/1024
            else if (v >= 1) printf \"%.0fG\", v
            else printf \"%dM\", v*1024
        }")

        raw_on_ki="yes"
        raw_on_dardel="no"
        if [ "${DARDEL_RAW_HAS[$sid]:-0}" = 1 ]; then
            raw_on_dardel="yes"
        fi

        ki_c=$(count_ki_processed "${sid}")
        dardel_c=${DARDEL_PROC_COUNT[$sid]:-0}
        dardel_batch=${DARDEL_PROC_BATCH[$sid]:-}

        # KI batch is just "results/" — there's no batch subdivision on KI for PFC; use literal "ki"
        ki_batch=""
        [ "${ki_c}" -gt 0 ] && ki_batch="ki_results"

        # Status classification
        notes=""
        if [ "${ki_c}" -eq "${n_probes}" ]; then
            status="on_ki"
            on_ki=$((on_ki+1))
        elif [ "${dardel_c}" -eq "${n_probes}" ] && [ "${ki_c}" -lt "${n_probes}" ]; then
            status="on_dardel_only"
            on_dardel_only=$((on_dardel_only+1))
            notes="processed on Dardel — needs sync to KI"
        elif [ "${ki_c}" -gt 0 ] || [ "${dardel_c}" -gt 0 ]; then
            status="partial"
            partial=$((partial+1))
            notes="partial probes processed"
        else
            status="pending"
            pending=$((pending+1))
            notes="not yet processed"
        fi

        echo "${sid},${animal},${sz},${sz_gb},${n_probes},${raw_on_ki},${raw_on_dardel},${ki_c}/${n_probes},${dardel_c}/${n_probes},${ki_batch},${dardel_batch},${status},${notes}"
    done

    echo "# Generated $(date '+%Y-%m-%d %H:%M')"
    echo "# Summary: ${total} sessions; ${on_ki} fully on KI; ${on_dardel_only} only on Dardel (need sync); ${partial} partial; ${pending} pending"
    echo "# Status values: on_ki | on_dardel_only | partial | pending"
    echo "# Columns: ki_processed and dardel_processed = N/<n_probes> probes with advanced_curation_kilosort4.json"
    echo "# Paths: raw=${KI_RAW}/<animal>/<sid>/; ki_proc=${KI_PROC}/<sid>/; dardel_raw=${DARDEL_RAW}/<animal>/<sid>/; dardel_proc=${DARDEL_PROC_BASE}/<batch>/results/<sid>/"
} > "${OUT_TMP}"

if [ "${OUT}" = "-" ]; then
    cat "${OUT_TMP}"
    rm -f "${OUT_TMP}"
else
    # CIFS-friendly write
    cat "${OUT_TMP}" > "${OUT}"
    rm -f "${OUT_TMP}"
    echo "Wrote: ${OUT}"
fi
echo
echo "Preview:"
column -s, -t < "${OUT}" 2>/dev/null | head -60

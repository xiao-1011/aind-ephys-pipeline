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
DEFAULT_OUT="${RAW_BASE}/MASTER_STATUS.md"

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
    ls "${imec0}"/shank*/advanced_curation_kilosort4.json 2>/dev/null | wc -l
}
count_ki() {
    local sid=$1
    for batch in "${KI_RESULTS_BASE}"/*/results/"${sid}"; do
        [ -d "${batch}" ] || continue
        local imec0="${batch}/${sid}_imec0"
        [ -d "${imec0}" ] || continue
        local c=$(ls "${imec0}"/shank*/advanced_curation_kilosort4.json 2>/dev/null | wc -l)
        if [ "${c}" -gt 0 ]; then
            echo "${c}"
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
{
    echo "# multishankv2 master status"
    echo
    echo "_Generated $(date '+%Y-%m-%d %H:%M') from raw (KI) + local + KI processed + Dardel state._"
    echo
    echo "| Session | Raw size | Dur | Local | KI | Dardel | KI batch | Dardel batch | Notes |"
    echo "|---|---:|---:|:---:|:---:|:---:|---|---|---|"

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
        sz=$(du -shL "${bin}" 2>/dev/null | cut -f1)
        [ -z "${sz}" ] && sz="?"

        dur_sec=$(grep -m1 fileTimeSecs "${meta}" 2>/dev/null | cut -d= -f2)
        if [ -n "${dur_sec}" ]; then
            dur_min=$(awk "BEGIN{printf \"%.0f\", ${dur_sec} / 60}")
            dur_disp="${dur_min}m"
        else
            dur_disp="?"
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

        local_mark=$(render_mark $local_c)
        ki_mark=$(render_mark $ki_c)
        dardel_mark=$(render_mark $dardel_c)

        # Summary counters
        if [ "${ki_c}" = 4 ] || [ "${local_c}" = 4 ] || [ "${dardel_c}" = 4 ]; then
            done_anywhere=$((done_anywhere+1))
            if [ "${ki_c}" != 4 ] && [ "${local_c}" != 4 ]; then
                only_dardel=$((only_dardel+1))
                [ -z "${notes}" ] && notes="on Dardel only — needs sync to KI"
            fi
        elif [ "${local_c}" != 0 ] || [ "${ki_c}" != 0 ] || [ "${dardel_c}" != 0 ]; then
            partial=$((partial+1))
            [ -z "${notes}" ] && notes="partial"
        else
            pending=$((pending+1))
            [ -z "${notes}" ] && notes="pending"
        fi

        echo "| \`${sid}\` | ${sz} | ${dur_disp} | ${local_mark} | ${ki_mark} | ${dardel_mark} | ${ki_batch:-—} | ${dardel_batch:-—} | ${notes} |"
    done

    echo
    echo "**Summary** • ${total} valid sessions • ${done_anywhere} fully sorted somewhere • ${only_dardel} only on Dardel (needs KI sync) • ${partial} partial • ${pending} pending • ${skipped} raw entries skipped (0-byte/corrupt meta)."
    echo
    echo "Legend: ✓ = 4/4 shanks adv-curated • N/4 = partial • ✗ = none."
    echo
    echo "Paths:"
    echo "- **Raw (KI)**: \`${RAW_BASE}/\` (root and \`batchN/\` subdirs)"
    echo "- **Local workstation**: \`${LOCAL_RESULTS}/<sid>/results/\`"
    echo "- **KI processed**: \`${KI_RESULTS_BASE}/<batch>/results/<sid>/\`"
    echo "- **Dardel processed**: \`${DARDEL_RESULTS_BASE}/<batch>/results/<sid>/\`"
} > "${OUT_TMP}"

if [ "${OUT}" = "-" ]; then
    cat "${OUT_TMP}"
    rm -f "${OUT_TMP}"
else
    mv "${OUT_TMP}" "${OUT}"
    echo "Wrote: ${OUT}"
    echo
    head -50 "${OUT}"
fi

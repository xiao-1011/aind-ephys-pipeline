#!/usr/bin/env bash
# multishankv2 status — what's in /mnt/dmclab/Anil/DATA_NPX, what's been
# sorted locally, what's been pushed to the KI results dir, with shank-level
# completeness. Re-runnable any time.
#
# Usage:
#   bash multishankv2_status.sh               # write markdown to default path
#   bash multishankv2_status.sh /tmp/foo.md   # custom output path
#   bash multishankv2_status.sh -             # stdout

set -euo pipefail

RAW_BASE="/mnt/dmclab/Anil/DATA_NPX"
LOCAL_RESULTS="/media/data/ephys-pipeline-output"
KI_RESULTS_BASE="/mnt/dmclab/Anil/ephys-pipeline-output"
DEFAULT_OUT="${RAW_BASE}/multishankv2_status.md"

OUT="${1:-${DEFAULT_OUT}}"

# Discover all sessions: any dir containing a `*_imec*` subdir with an .ap.meta
# Search depth covers DATA_NPX/<session>/<imec>/ and DATA_NPX/batchN/<session>/<imec>/
mapfile -t METAS < <(find "${RAW_BASE}" -maxdepth 5 -name "*.ap.meta" 2>/dev/null | sort)

# Helper: count published adv_curate files for a session under a given results root.
# Expected layout: <root>/<sid>/results/<sid>/<sid>_imec0/shank{0..3}/advanced_curation_kilosort4.json
# OR:             <root>/<sid>/<sid>_imec0/shank{0..3}/advanced_curation_kilosort4.json
count_adv_curate_local() {
    local sid=$1
    local imec0="${LOCAL_RESULTS}/${sid}/results/${sid}/${sid}_imec0"
    [ -d "${imec0}" ] || { echo 0; return; }
    ls "${imec0}"/shank*/advanced_curation_kilosort4.json 2>/dev/null | wc -l
}
count_adv_curate_ki() {
    local sid=$1
    # Scan all batch dirs on KI for this session
    local count=0
    for batch in "${KI_RESULTS_BASE}"/*/results/"${sid}"; do
        [ -d "${batch}" ] || continue
        local imec0="${batch}/${sid}_imec0"
        [ -d "${imec0}" ] || continue
        count=$(ls "${imec0}"/shank*/advanced_curation_kilosort4.json 2>/dev/null | wc -l)
        if [ "${count}" -gt 0 ]; then
            echo "${count}"
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

# Emit
{
    echo "# multishankv2-local processing status"
    echo
    echo "_Generated $(date '+%Y-%m-%d %H:%M') from local + KI server state._"
    echo
    echo "| Session | Raw size | Duration | Local | KI server | Batch | Notes |"
    echo "|---|---:|---:|:---:|:---:|---|---|"

    total=0; full_local=0; full_ki=0; partial=0; pending=0
    for meta in "${METAS[@]}"; do
        # Derive session id from the imec dir name (more robust than walking
        # up the path, which fails on nested layouts like .../recording/<imec>/)
        imec_dir=$(dirname "${meta}")
        imec_base=$(basename "${imec_dir}")            # e.g. 2026-05-20_1005255_reaching_g0_imec0
        sid="${imec_base%_imec*}"                       # strips trailing _imec[0-9]

        # Skip if sid doesn't match the expected session pattern (date_animal_..._gN)
        case "${sid}" in
            ????-??-??_*_g[0-9]*) ;;
            *) continue ;;
        esac

        # Skip obvious non-real recordings (very small or empty meta)
        meta_size=$(stat -c %s "${meta}" 2>/dev/null || echo 0)
        if [ "${meta_size}" -lt 1000 ]; then
            continue   # 0-byte / aborted meta
        fi

        total=$((total+1))

        bin="${meta%.meta}.bin"
        sz=$(du -shL "${bin}" 2>/dev/null | cut -f1)
        [ -z "${sz}" ] && sz="?"

        dur_sec=$(grep -m1 fileTimeSecs "${meta}" 2>/dev/null | cut -d= -f2)
        if [ -n "${dur_sec}" ]; then
            dur_min=$(awk "BEGIN{printf \"%.0f\", ${dur_sec} / 60}")
            dur_disp="${dur_min} min"
        else
            dur_disp="?"
        fi
        # Mark very short recordings as test
        notes=""
        if [ -n "${dur_sec}" ] && [ "$(awk "BEGIN{print (${dur_sec} < 600)}")" = "1" ]; then
            notes="short (likely test)"
        fi

        # Local + KI completeness (count of 4 expected shanks)
        local_c=$(count_adv_curate_local "${sid}")
        ki_c=$(count_adv_curate_ki "${sid}")
        ki_batch=$(ki_batch_for "${sid}")

        local_mark="✗"
        case "${local_c}" in
            4) local_mark="✓"; full_local=$((full_local+1)) ;;
            0) local_mark="✗" ;;
            *) local_mark="${local_c}/4"; [ -z "${notes}" ] && notes="partial: ${local_c}/4 shanks" ;;
        esac

        ki_mark="✗"
        if [ "${ki_c}" = 4 ]; then
            ki_mark="✓"
            full_ki=$((full_ki+1))
        elif [ "${ki_c}" != 0 ]; then
            ki_mark="${ki_c}/4"
            [ -z "${notes}" ] && notes="partial KI: ${ki_c}/4 shanks"
        fi

        if [ "${local_c}" = 0 ] && [ "${ki_c}" = 0 ]; then
            pending=$((pending+1))
        elif [ "${local_c}" != 4 ] && [ "${ki_c}" != 4 ]; then
            partial=$((partial+1))
        fi

        echo "| \`${sid}\` | ${sz} | ${dur_disp} | ${local_mark} | ${ki_mark} | ${ki_batch:-—} | ${notes} |"
    done

    echo
    echo "**Summary:** ${total} sessions • ${full_ki} fully on KI • ${full_local} fully local • ${partial} partial • ${pending} pending."
    echo
    echo "Legend: ✓ = 4/4 shanks adv-curated, N/4 = partial, ✗ = none."
    echo
    echo "Paths:"
    echo "- Raw: \`${RAW_BASE}/\` (and \`${RAW_BASE}/batchN/\`)"
    echo "- Local out: \`${LOCAL_RESULTS}/\`"
    echo "- KI out: \`${KI_RESULTS_BASE}/<batch>/results/\`"
} > "${OUT_TMP:=/tmp/_msv2_status.$$}"

if [ "${OUT}" = "-" ]; then
    cat "${OUT_TMP}"
else
    mv "${OUT_TMP}" "${OUT}"
    echo "Wrote: ${OUT}"
    echo
    head -30 "${OUT}"
    echo "..."
fi

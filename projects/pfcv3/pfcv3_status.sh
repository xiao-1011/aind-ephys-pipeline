#!/usr/bin/env bash
# pfcv3 status — what's in Joana/Raw_data on Dardel, what's processed,
# what's pending. Re-runnable any time; just shows current state.
#
# Usage:
#   bash pfcv3_status.sh                 # print markdown to stdout
#   bash pfcv3_status.sh > status.md     # save to a file

set -euo pipefail

RAW_DIR="/cfs/klemming/projects/supr/dmclab/Joana/Raw_data"
OUT_BASE="/cfs/klemming/projects/supr/dmclab/ephys-pipeline-output"

# Pull lists from Dardel in one SSH round-trip
DATA=$(ssh dardel "
echo '=== SESSIONS ==='
find $RAW_DIR -mindepth 2 -maxdepth 2 -type d -name '*_g[0-9]*' \\! -name '*_imec*' 2>/dev/null \\
    | xargs -I{} basename {} | sort -u

echo '=== PROCESSED ==='
# A session is 'processed' if it has at least one *_imec dir with a sorter_kilosort4 OR sorter_tridesclous2
for batch in $OUT_BASE/*/results; do
    [ -d \"\$batch\" ] || continue
    batch_name=\$(basename \$(dirname \$batch))
    for s in \$batch/*/; do
        sid=\$(basename \$s)
        [ \"\$sid\" = nextflow ] && continue
        # Check if at least one probe has sorter output
        has_ks4=0; has_tdc2=0; has_sc2=0
        for p in \$s/*_imec*; do
            [ -d \$p ] || continue
            [ -d \$p/sorter_kilosort4 ] && has_ks4=1
            [ -d \$p/sorter_tridesclous2 ] && has_tdc2=1
            [ -d \$p/sorter_spykingcircus2 ] && has_sc2=1
        done
        printf '%s\t%s\t%d\t%d\t%d\n' \"\$sid\" \"\$batch_name\" \$has_ks4 \$has_tdc2 \$has_sc2
    done
done
")

# Parse
all_sessions=$(echo "$DATA" | awk '/^=== SESSIONS ===$/,/^=== PROCESSED ===$/' | sed '1d;$d')
processed_table=$(echo "$DATA" | awk '/^=== PROCESSED ===$/,0' | sed '1d')

# Build maps
declare -A SORTERS BATCH
while IFS=$'\t' read -r sid batch ks tdc sc2; do
    [ -z "$sid" ] && continue
    sorters=""
    [ "$ks" = 1 ] && sorters+="KS4 "
    [ "$tdc" = 1 ] && sorters+="TDC2 "
    [ "$sc2" = 1 ] && sorters+="SC2 "
    SORTERS[$sid]="${sorters% }"
    BATCH[$sid]="$batch"
done <<< "$processed_table"

# Render markdown
echo "# pfcv3 — Joana/Raw_data processing status"
echo
echo "_Generated $(date '+%Y-%m-%d %H:%M') from Dardel state._"
echo
echo "| Session | Status | Sorters | Batch |"
echo "|---|:---:|---|---|"

pending_count=0
done_count=0
while read -r sid; do
    [ -z "$sid" ] && continue
    if [ -n "${SORTERS[$sid]:-}" ]; then
        echo "| \`$sid\` | ✓ done | ${SORTERS[$sid]} | ${BATCH[$sid]} |"
        done_count=$((done_count+1))
    else
        echo "| \`$sid\` | ✗ **pending** | — | — |"
        pending_count=$((pending_count+1))
    fi
done <<< "$all_sessions"

echo
echo "**Summary:** $done_count done, $pending_count pending."
echo
if [ $pending_count -gt 0 ]; then
    echo "## Pending sessions (ready to process)"
    echo
    echo '```'
    while read -r sid; do
        [ -z "$sid" ] && continue
        [ -z "${SORTERS[$sid]:-}" ] && echo "$sid"
    done <<< "$all_sessions"
    echo '```'
    echo
    echo "## To kick off the next batch"
    echo
    echo "1. Pick a batch number (next: \`batch4\`)."
    echo "2. Create the staging dir on Dardel and symlink the pending sessions:"
    echo
    echo '```bash'
    echo 'ssh dardel "mkdir -p /cfs/klemming/projects/supr/dmclab/Joana/ephys_batchN'
    echo 'cd /cfs/klemming/projects/supr/dmclab/Joana/ephys_batchN'
    echo 'for s in <pending-list>; do'
    echo '    animal=${s%%_*}'
    echo '    ln -sfn /cfs/klemming/projects/supr/dmclab/Joana/Raw_data/$animal/$s $s'
    echo 'done"'
    echo '```'
    echo
    echo "3. Copy & adapt \`slurm_submit_batch3.sh\` → \`slurm_submit_batchN.sh\` (change \`ephys_batch3\` → \`ephys_batchN\`, \`pfcv3-batch3\` → \`pfcv3-batchN\`)."
    echo "4. \`git push\`, \`ssh dardel \"... git pull\"\`, then \`sbatch slurm_submit_batchN.sh\`."
fi

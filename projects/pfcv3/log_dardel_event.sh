#!/usr/bin/env bash
# Append an event to PFC_DARDEL_TIMELINE.csv.
#
# Usage:
#   log_dardel_event.sh <action> <scope> <animal-or-empty> <batch-or-empty> "<notes>"
#
# Args:
#   action  = uploaded | deleted | processed | synced_to_ki
#   scope   = animal | session | batch
#   animal  = animal number (e.g. 1061220) OR - for whole-batch events
#   batch   = batch tag (e.g. pfcv3-batch7, batch7-candidate) OR - if not applicable
#   notes   = free text, quote it
#
# Examples:
#   log_dardel_event.sh uploaded animal 1061220 pfcv3-batch7 "4 days"
#   log_dardel_event.sh deleted  batch  -       pfcv3-batch6 "6.3 TB freed after KI sync verified"
#   log_dardel_event.sh processed batch -       pfcv3-batch7 "all 23 sessions KS4=2 TDC2=2"
#
# Date is filled in as today (YYYY-MM-DD).

set -euo pipefail

CSV="/mnt/dmclab/Joana/PFC-Str_behavior_project/Analysis/PFC_DARDEL_TIMELINE.csv"

if [ $# -lt 5 ]; then
    sed -n '2,20p' "$0"  # print help header
    exit 1
fi

action=$1; scope=$2; animal=$3; batch=$4; notes=$5
date=$(date '+%Y-%m-%d')

# Whitelist checks (fail fast on typos)
case "$action" in
    uploaded|deleted|processed|synced_to_ki) ;;
    *) echo "action must be one of: uploaded deleted processed synced_to_ki" >&2; exit 1 ;;
esac
case "$scope" in
    animal|session|batch) ;;
    *) echo "scope must be one of: animal session batch" >&2; exit 1 ;;
esac

# CSV-safe the notes (strip commas → semicolons; quotes → single-quote)
notes_safe=$(echo "$notes" | tr ',' ';' | tr '"' "'")

# CIFS-friendly append
row="${date},${action},${scope},${animal},${batch},${notes_safe}"
printf '%s\n' "${row}" >> "${CSV}"
echo "logged: ${row}"

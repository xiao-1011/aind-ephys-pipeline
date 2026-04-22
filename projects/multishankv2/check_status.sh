#!/bin/bash
# Usage: bash check_status.sh [results_path]
# Default: current directory's results/

RESULTS="${1:-/cfs/klemming/projects/supr/dmclab/ephys-pipeline-output/multishankv2-batch2/results}"

SORTERS=("sorter_kilosort4" "sorter_spykingcircus2" "sorter_tridesclous2")
ANALYZERS=("analyzer_kilosort4" "analyzer_spykingcircus2" "analyzer_tridesclous2")
CURATE=("advanced_curation_kilosort4.json" "advanced_curation_spykingcircus2.json" "advanced_curation_tridesclous2.json")
SORTER_LABELS=("KS4" "SC2" "TDC2")

# Header
printf "%-45s | %-14s | %-14s | %-14s | %-14s | %-14s | %-14s | %-14s | %-14s | %-14s\n" \
    "Session/Probe" \
    "KS4-sort" "SC2-sort" "TDC2-sort" \
    "KS4-analyze" "SC2-analyze" "TDC2-analyze" \
    "KS4-curate" "SC2-curate" "TDC2-curate"
printf '%0.s-' {1..200}
echo

# Iterate sessions
for session_dir in $(ls -d "${RESULTS}"/*/  2>/dev/null | sort); do
    session=$(basename "$session_dir")
    for probe_dir in $(ls -d "${session_dir}"*/  2>/dev/null | sort); do
        probe=$(basename "$probe_dir")

        # Collect per-shank results
        ks4_sort=0;  sc2_sort=0;  tdc2_sort=0
        ks4_ana=0;   sc2_ana=0;   tdc2_ana=0
        ks4_cur=0;   sc2_cur=0;   tdc2_cur=0
        total_shanks=0

        for shank_dir in $(ls -d "${probe_dir}"shank*/  2>/dev/null | sort); do
            total_shanks=$((total_shanks + 1))
            [ -d "${shank_dir}sorter_kilosort4" ]   && ks4_sort=$((ks4_sort+1))
            [ -d "${shank_dir}sorter_spykingcircus2" ] && sc2_sort=$((sc2_sort+1))
            [ -d "${shank_dir}sorter_tridesclous2" ]   && tdc2_sort=$((tdc2_sort+1))
            [ -d "${shank_dir}analyzer_kilosort4" ]  && ks4_ana=$((ks4_ana+1))
            [ -d "${shank_dir}analyzer_spykingcircus2" ] && sc2_ana=$((sc2_ana+1))
            [ -d "${shank_dir}analyzer_tridesclous2" ]   && tdc2_ana=$((tdc2_ana+1))
            [ -f "${shank_dir}advanced_curation_kilosort4.json" ]    && ks4_cur=$((ks4_cur+1))
            [ -f "${shank_dir}advanced_curation_spykingcircus2.json" ] && sc2_cur=$((sc2_cur+1))
            [ -f "${shank_dir}advanced_curation_tridesclous2.json" ]   && tdc2_cur=$((tdc2_cur+1))
        done

        n=$total_shanks
        _fmt() { local v=$1; local n=$2
            if [ "$v" -eq "$n" ]; then echo "✓ ${v}/${n}"
            elif [ "$v" -eq 0 ]; then echo "✗ 0/${n}"
            else echo "~ ${v}/${n}"; fi
        }

        printf "%-45s | %-14s | %-14s | %-14s | %-14s | %-14s | %-14s | %-14s | %-14s | %-14s\n" \
            "${session}/${probe}" \
            "$(_fmt $ks4_sort $n)" "$(_fmt $sc2_sort $n)" "$(_fmt $tdc2_sort $n)" \
            "$(_fmt $ks4_ana $n)"  "$(_fmt $sc2_ana $n)"  "$(_fmt $tdc2_ana $n)" \
            "$(_fmt $ks4_cur $n)"  "$(_fmt $sc2_cur $n)"  "$(_fmt $tdc2_cur $n)"
    done
done

#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# batch5 orchestrator — sequentially sort all unprocessed batch5 sessions on
# the workstation, then rsync each session's results to the KI server.
#
# Source data:  /mnt/dmclab/Anil/DATA_NPX/batch5/<session>
# Local work:   /home/anil/ephys-work/<session>           (SSD; cleaned per session)
# Local out:    /media/data/ephys-pipeline-output/<session>/results
# KI dest:      /mnt/dmclab/Anil/ephys-pipeline-output/batch5/results/<session>
#
# Skips sessions whose results dir is already present locally OR on KI.
# After each session: rsync to KI, then (on success) delete the SSD work dir.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_LOCAL="${SCRIPT_DIR}/run_local.sh"

SOURCE_BASE="/mnt/dmclab/Anil/DATA_NPX/batch5"
LOCAL_RESULTS_BASE="/media/data/ephys-pipeline-output"
LOCAL_WORK_BASE="/home/anil/ephys-work"
KI_DEST="/mnt/dmclab/Anil/ephys-pipeline-output/batch5/results"

LOG_DIR="/media/data/ephys-pipeline-output/_batch5_logs"
mkdir -p "${LOG_DIR}" "${KI_DEST}"

# Sessions to process (5 real + 1 already-done that just needs rsync)
SESSIONS=(
    2026-05-20_1005255_reaching_g0
    2026-05-20_1005257_reaching_g0
    2026-05-20_1021202_reaching_g0
    2026-05-21_1005255_reaching_g0
    2026-05-21_1021202_reaching_g0
    2026-05-25_1021202_reaching_g0   # already sorted earlier today
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

rsync_session_to_ki() {
    local sid=$1
    local src="${LOCAL_RESULTS_BASE}/${sid}/results/${sid}"
    if [ ! -d "${src}" ]; then
        log "  SKIP rsync (no local results at ${src})"
        return 1
    fi
    log "  rsync -> KI server (${KI_DEST}/${sid})"
    rsync -avL --partial --info=progress2 \
        "${src}/" "${KI_DEST}/${sid}/" \
        2>&1 | tail -5
    log "  rsync done"
}

cleanup_work_dir() {
    local sid=$1
    local workdir="${LOCAL_WORK_BASE}/${sid}"
    if [ -d "${workdir}" ]; then
        local sz
        sz=$(du -sh "${workdir}" 2>/dev/null | cut -f1)
        log "  cleaning SSD work dir ${workdir} (${sz})"
        # Tolerant of root-owned stragglers from lupin container (a few KB-MB
        # of tiny files in sorting_clean_kilosort4/). The bulk gets freed.
        rm -rf "${workdir}" 2>/dev/null || true
        if [ -d "${workdir}" ]; then
            local remaining
            remaining=$(du -sh "${workdir}" 2>/dev/null | cut -f1)
            log "  (left ${remaining} of root-owned stragglers — harmless, will sudo-clean later)"
        fi
    fi
}

for sid in "${SESSIONS[@]}"; do
    echo
    log "===== ${sid} ====="

    src="${SOURCE_BASE}/${sid}"
    if [ ! -d "${src}" ]; then
        log "  ERROR: source not found at ${src}, skipping"
        continue
    fi

    local_done="${LOCAL_RESULTS_BASE}/${sid}/results/${sid}/${sid}_imec0/shank3/advanced_curation_kilosort4.json"
    ki_done="${KI_DEST}/${sid}/${sid}_imec0/shank3/advanced_curation_kilosort4.json"

    if [ -f "${ki_done}" ]; then
        log "  KI already has full results — skipping"
        continue
    fi

    if [ -f "${local_done}" ]; then
        log "  local results already present, jumping to rsync"
    else
        log "  running multishankv2-local pipeline (DATA_PATH=${src})"
        DATA_PATH="${src}" bash "${RUN_LOCAL}" \
            > "${LOG_DIR}/${sid}.log" 2>&1
        log "  pipeline finished"

        if [ ! -f "${local_done}" ]; then
            log "  WARNING: expected output missing after run — see ${LOG_DIR}/${sid}.log"
            continue
        fi
    fi

    if rsync_session_to_ki "${sid}"; then
        # Sanity check: KI side has at least one shank's advanced_curation
        if [ -f "${ki_done}" ]; then
            cleanup_work_dir "${sid}"
        else
            log "  WARNING: KI rsync didn't produce expected file — keeping work dir"
        fi
    fi
done

echo
log "===== batch5 done ====="
log "logs in: ${LOG_DIR}/"
log "results in (local): ${LOCAL_RESULTS_BASE}/2026-05-*/results"
log "results in (KI):    ${KI_DEST}/"

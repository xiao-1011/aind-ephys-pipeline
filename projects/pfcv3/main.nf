#!/usr/bin/env nextflow
nextflow.enable.dsl = 2

// ─────────────────────────────────────────────────────────────────────────────
// Input channel
//
// Accepts two layouts:
//   --data_path /sessions_parent/          → discovers all sessions and probes
//   --data_path /sessions_parent/session1/ → single session, all probes
//
// A SpikeGLX probe directory is identified by the presence of *.ap.meta files.
// Recording duration is parsed from the .meta file (fileTimeSecs field) and
// threaded through all processes for dynamic SLURM time allocation.
//
// The channel emits: (session_name, probe_name, duration_minutes, probe_dir_path)
// ─────────────────────────────────────────────────────────────────────────────

def discoverProbes() {
    Channel
        .fromPath("${params.data_path}/**/*.ap.meta")
        .map { meta ->
            // Parse fileTimeSecs from the SpikeGLX .meta file
            def duration_sec = 0
            meta.text.eachLine { line ->
                if (line.startsWith('fileTimeSecs=')) {
                    duration_sec = line.split('=')[1].trim().toFloat()
                }
            }
            if (params.test_duration_sec > 0) {
                duration_sec = Math.min(duration_sec, params.test_duration_sec as float)
            }
            def duration_min = Math.max(1, Math.ceil(duration_sec / 60.0) as int)
            def probe_dir = meta.parent
            def probe_str = probe_dir.toString()
            def sid   = file(probe_str).parent.name
            def probe = file(probe_str).name
            tuple(sid, probe, duration_min, probe_dir)
        }
        .unique { it[0..2] }  // deduplicate by session + probe + duration
}

// ─────────────────────────────────────────────────────────────────────────────
// Processes
// ─────────────────────────────────────────────────────────────────────────────

process PREPROCESS {
    tag "${sid}/${probe}"

    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(duration_minutes), path(probe_dir)

    output:
    tuple val(sid), val(probe), val(duration_minutes), path('preprocessed'), emit: preprocessed
    path 'motion_*',                                                             emit: motion, optional: true

    script:
    """
    python ${projectDir}/scripts/01-preprocess.py \\
        ${probe_dir} \\
        . \\
        ${params.test_duration_sec > 0 ? "--max-duration-sec ${params.test_duration_sec}" : ''}
    """
}

// SORT_KS4_BATCH: batch up to 4 probes onto a single GPU node (4 GPUs).
// buffer(size:4, remainder:true) collects probes as they finish PREPROCESS.
// Each probe gets its own GPU via CUDA_VISIBLE_DEVICES.
// 4x GPU allocation savings vs. separate exclusive GPU node per probe.
process SORT_KS4_BATCH {
    tag "batch[${sids.join(',')}]"

    // No publishDir — sorter output published indirectly via ANALYZE downstream.
    // Avoids complex per-probe publish logic in a batched process.

    input:
    tuple val(sids), val(probes), val(durs), path(preproc_dirs, stageAs: 'preproc_?')

    output:
    tuple val(sids), val(probes), val(durs),
          path('probe_*/sorter_kilosort4'), emit: sorters

    script:
    def n = sids.size()
    """
    # Set up per-probe work directories with preprocessed symlinks
    # stageAs 'preproc_?' produces preproc_1, preproc_2, ... (1-based)
    for i in \$(seq 0 \$((${n} - 1))); do
        mkdir -p probe_\${i}
        ln -s \$(readlink -f preproc_\$((i + 1))) probe_\${i}/preprocessed
    done

    # Run all sorts in parallel — one GPU per probe
    pids=()
    for i in \$(seq 0 \$((${n} - 1))); do
        CUDA_VISIBLE_DEVICES=\$i python ${projectDir}/scripts/02-sort.py \\
            probe_\${i} --sorters kilosort4 &
        pids+=(\$!)
    done

    # Wait for all — fail if any fail
    for pid in "\${pids[@]}"; do
        wait \$pid
    done
    """
}

process SORT_SC2 {
    tag "${sid}/${probe}"

    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(duration_minutes), path('preprocessed')

    output:
    tuple val(sid), val(probe), val(duration_minutes), path('sorter_spykingcircus2'), emit: sorter

    script:
    """
    python ${projectDir}/scripts/02-sort.py \\
        . \\
        --sorters spykingcircus2
    """
}

// SORT_MS5: disabled — consistently fails across all probes.
// process SORT_MS5 {
//     tag "${sid}/${probe}"
//     errorStrategy 'ignore'
//     publishDir "${params.results_path}/${sid}/${probe}",
//                mode: params.publish_mode, overwrite: true
//     input:
//     tuple val(sid), val(probe), val(duration_minutes), path('preprocessed')
//     output:
//     tuple val(sid), val(probe), val(duration_minutes), path('sorter_mountainsort5'), emit: sorter
//     script:
//     """
//     python ${projectDir}/scripts/02-sort.py . --sorters mountainsort5
//     """
// }

process SORT_TDC2 {
    tag "${sid}/${probe}"
    errorStrategy 'ignore'

    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(duration_minutes), path('preprocessed')

    output:
    tuple val(sid), val(probe), val(duration_minutes), path('sorter_tridesclous2'), emit: sorter

    script:
    """
    python ${projectDir}/scripts/02-sort.py \\
        . \\
        --sorters tridesclous2
    """
}

process SORT_LUPIN {
    tag "${sid}/${probe}"
    errorStrategy 'ignore'

    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(duration_minutes), path('preprocessed')

    output:
    tuple val(sid), val(probe), val(duration_minutes), path('sorter_lupin'), emit: sorter

    script:
    """
    python ${projectDir}/scripts/02-sort.py \\
        . \\
        --sorters lupin
    """
}

process COMPARE {
    tag "${sid}/${probe}"

    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(duration_minutes), path(sorter_dirs)

    output:
    tuple val(sid), val(probe), val(duration_minutes), path('consensus_labels.json'), emit: consensus
    path 'consensus_plots',                                                               emit: plots, optional: true

    script:
    """
    python ${projectDir}/scripts/06-compare.py \\
        . \\
        --agreement-threshold ${params.consensus_agreement_threshold} \\
        --min-agreement       ${params.consensus_min_agreement}
    """
}

// ANALYZE split per-sorter: KS4/SC2 need large nodes (up to 396 GB RSS),
// while TDC2/MS5 fit on shared (155 GB / 51 GB). Same script, different
// resource allocations via nextflow.config process selectors.

process ANALYZE_KS4 {
    tag "${sid}/${probe}/${sorter_dir.name}"
    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true
    input:
    tuple val(sid), val(probe), val(duration_minutes),
          path('preprocessed'), path(sorter_dir)
    output:
    tuple val(sid), val(probe), val(duration_minutes),
          path('analyzer_*'), emit: analyzer
    script:
    """
    python ${projectDir}/scripts/03-analyze.py . --sorter_folder ${sorter_dir}
    """
}

process ANALYZE_SC2 {
    tag "${sid}/${probe}/${sorter_dir.name}"
    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true
    input:
    tuple val(sid), val(probe), val(duration_minutes),
          path('preprocessed'), path(sorter_dir)
    output:
    tuple val(sid), val(probe), val(duration_minutes),
          path('analyzer_*'), emit: analyzer
    script:
    """
    python ${projectDir}/scripts/03-analyze.py . --sorter_folder ${sorter_dir}
    """
}

process ANALYZE_TDC2 {
    tag "${sid}/${probe}/${sorter_dir.name}"
    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true
    input:
    tuple val(sid), val(probe), val(duration_minutes),
          path('preprocessed'), path(sorter_dir)
    output:
    tuple val(sid), val(probe), val(duration_minutes),
          path('analyzer_*'), emit: analyzer
    script:
    """
    python ${projectDir}/scripts/03-analyze.py . --sorter_folder ${sorter_dir}
    """
}

// ANALYZE_MS5: disabled — MS5 sorter consistently fails.
// process ANALYZE_MS5 {
//     tag "${sid}/${probe}/${sorter_dir.name}"
//     publishDir "${params.results_path}/${sid}/${probe}",
//                mode: params.publish_mode, overwrite: true
//     input:
//     tuple val(sid), val(probe), val(duration_minutes),
//           path('preprocessed'), path(sorter_dir)
//     output:
//     tuple val(sid), val(probe), val(duration_minutes),
//           path('analyzer_*'), emit: analyzer
//     script:
//     """
//     python ${projectDir}/scripts/03-analyze.py . --sorter_folder ${sorter_dir}
//     """
// }

// ANALYZE_LUPIN uses the lupin container (SI 0.104.0) since it must read
// lupin's sorting output format. Identical script to ANALYZE.
process ANALYZE_LUPIN {
    tag "${sid}/${probe}/${sorter_dir.name}"

    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(duration_minutes),
          path('preprocessed'), path(sorter_dir)

    output:
    tuple val(sid), val(probe), val(duration_minutes),
          path('analyzer_*'), emit: analyzer

    script:
    """
    python ${projectDir}/scripts/03-analyze.py . --sorter_folder ${sorter_dir}
    """
}

// ADVANCED_CURATE runs per-sorter: redundant removal, UnitRefine noise
// classification, auto-merge of split units, bombcell labels, SUA/MUA labels.
// Produces a clean sorting (sorting_clean_*) for COMPARE_CLEAN and label JSONs.
process ADVANCED_CURATE {
    tag "${sid}/${probe}/${analyzer_dir.name}"

    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(duration_minutes),
          path('preprocessed'), path(analyzer_dir)

    output:
    tuple val(sid), val(probe), val(duration_minutes),
          path('sorting_clean_*'),              emit: clean_sorting
    tuple val(sid), val(probe), val(duration_minutes),
          path('advanced_curation_*.json'),     emit: adv_labels
    path(analyzer_dir)  // re-publish with bombcell/unitrefine/passing_qc JSONs

    script:
    """
    python ${projectDir}/scripts/07-advanced-curate.py . --analyzer_folder ${analyzer_dir}
    """
}

// ADV_CURATE_LPN: identical script, uses lupin container (set in nextflow.config).
process ADV_CURATE_LPN {
    tag "${sid}/${probe}/${analyzer_dir.name}"

    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(duration_minutes),
          path('preprocessed'), path(analyzer_dir)

    output:
    tuple val(sid), val(probe), val(duration_minutes),
          path('sorting_clean_*'),              emit: clean_sorting
    tuple val(sid), val(probe), val(duration_minutes),
          path('advanced_curation_*.json'),     emit: adv_labels
    path(analyzer_dir)  // re-publish with bombcell/unitrefine/passing_qc JSONs

    script:
    """
    python ${projectDir}/scripts/07-advanced-curate.py . --analyzer_folder ${analyzer_dir}
    """
}

// COMPARE_CLEAN runs on the clean sortings (post noise-removal + merge).
// Uses same 06-compare.py script with different prefix/output args.
process COMPARE_CLEAN {
    tag "${sid}/${probe}"
    errorStrategy 'ignore'

    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(duration_minutes), path(clean_dirs)

    output:
    tuple val(sid), val(probe), val(duration_minutes),
          path('consensus_clean.json'),    emit: consensus_clean
    path 'consensus_clean_plots',          emit: plots, optional: true

    script:
    """
    python ${projectDir}/scripts/06-compare.py \\
        . \\
        --input-prefix sorting_clean_ \\
        --output-name consensus_clean.json \\
        --plot-dir-name consensus_clean_plots \\
        --agreement-threshold ${params.consensus_agreement_threshold} \\
        --min-agreement       ${params.consensus_min_agreement}
    """
}

// CONSENSUS_DELTA compares raw vs clean consensus and produces delta plots.
process CONSENSUS_DELTA {
    tag "${sid}/${probe}"

    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(duration_minutes),
          path('consensus_labels.json'), path('consensus_clean.json')

    output:
    path 'consensus_delta', emit: delta_plots

    script:
    """
    python ${projectDir}/scripts/08-consensus-delta.py \\
        . \\
        --raw consensus_labels.json \\
        --clean consensus_clean.json
    """
}

process CURATE {
    tag "${sid}/${probe}"

    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(duration_minutes),
          path(analyzer_dirs), path('consensus_labels.json'),
          path('consensus_clean.json'), path(adv_label_files)

    output:
    tuple val(sid), val(probe), val(duration_minutes), path('curation_*.json'), emit: curation

    script:
    """
    python ${projectDir}/scripts/04-curate.py \\
        . \\
        --isi-max              ${params.curation_isi_max} \\
        --presence-min         ${params.curation_presence_min} \\
        --amplitude-cutoff-max ${params.curation_amplitude_cutoff_max}
    """
}

process NWB_EXPORT {
    tag "${sid}/${probe}"

    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(duration_minutes),
          path('preprocessed'), path(sorter_dirs), path(curation_files)

    output:
    tuple val(sid), val(probe), path('*.nwb'), emit: nwb

    script:
    """
    python ${projectDir}/scripts/05-export-nwb.py \\
        . \\
        --session-id ${sid} \\
        --probe-id   ${probe}
    """
}

// ─────────────────────────────────────────────────────────────────────────────
// Workflow
//
// DAG (per probe, all parallel across probes):
//
//   PREPROCESS ──→ buffer(4) ──→ SORT_KS4_BATCH (1 GPU node, 4 GPUs) ──→ flatMap
//     │                                                                      │
//     ├─→ SORT_SC2   (CPU, immediate) ──→ ┐                                  │
//     ├─→ SORT_TDC2  (CPU, immediate) ──→ ├── + ks4 ──→ COMPARE (raw) ──────────→ ┐
//     └─→ SORT_LUPIN (CPU, immediate) ──→ ┘                                       │
//                                                                                  │
//     ks4 ──→ ANALYZE_KS4 (main)  ─┐                                              │
//     sc2 ──→ ANALYZE_SC2 (main)  ─┤──→ ADV_CURATE ──→ ┐                          │
//     tdc2──→ ANALYZE_TDC2 (shared)─┘                    ├→ COMPARE_CLEAN ─→ ┐     │
//     lupin─→ ANALYZE_LUPIN (shared)──→ ADV_LPN ───────→┘    └─→ CONSENSUS_DELTA  │
//                                                                            │     │
//                                                            CURATE ←────────┘←────┘
//                                                              │
//                                                                                 [NWB_EXPORT]
//
// KS4 uses buffer(size:4, remainder:true) to batch 4 probes per GPU node.
// CPU sorters run immediately per-probe; KS4 fires when 4 probes are ready.
// COMPARE waits naturally for KS4 (groupTuple needs all sorters).
//
// Optional sorters (TDC2, Lupin) use errorStrategy 'ignore'.
// NWB_EXPORT is off by default (params.run_nwb_export).
// SLURM time allocations scale with recording duration (parsed from .ap.meta).
// ─────────────────────────────────────────────────────────────────────────────

workflow {

    probes_ch = discoverProbes()
    probes_ch.view { sid, probe, dur, _ -> "Discovered probe: ${sid}/${probe} (${dur} min)" }

    preprocess_out = PREPROCESS(probes_ch)

    // ── KS4: batch up to 4 probes onto 1 GPU node (4 GPUs) ──────────────
    // Deterministic batch assignments: sort probes alphabetically and assign
    // batch index = floor(i / 4).  Computed at discovery time (instant
    // filesystem scan) so the mapping is fixed before any SLURM scheduling.
    // groupTuple(by: batch_idx) fires each batch independently — no stall.
    if (params.run_ks4) {
        ks4_batch_map = discoverProbes()
            .toSortedList { a, b -> "${a[0]}/${a[1]}" <=> "${b[0]}/${b[1]}" }
            .flatMap { sorted ->
                sorted.withIndex().collect { item, idx ->
                    tuple("${item[0]}/${item[1]}", (int)(idx / 4))
                }
            }

        ks4_batch_ch = preprocess_out.preprocessed
            .map { sid, probe, dur, dir -> tuple("${sid}/${probe}", sid, probe, dur, dir) }
            .combine(ks4_batch_map, by: 0)
            .map { key, sid, probe, dur, dir, batch_idx -> tuple(batch_idx, sid, probe, dur, dir) }
            .groupTuple(by: 0)
            .map { batch_idx, sids, probes, durs, dirs ->
                tuple(sids, probes, durs, dirs)
            }

        sort_ks4_batch_out = SORT_KS4_BATCH(ks4_batch_ch)

        sort_ks4_individual = sort_ks4_batch_out.sorters
            .flatMap { sids, probes, durs, sorter_dirs ->
                def dir_list = (sorter_dirs instanceof List) ? sorter_dirs : [sorter_dirs]
                dir_list.collect { dir ->
                    def idx = dir.parent.name.replace('probe_', '').toInteger()
                    tuple(sids[idx], probes[idx], durs[idx], dir)
                }
            }
    } else {
        sort_ks4_individual = Channel.empty()
    }

    // CPU sorters run immediately per-probe (no batching, no waiting)
    sort_sc2_out   = params.run_sc2   ? SORT_SC2(preprocess_out.preprocessed)   : null
    sort_tdc2_out  = params.run_tdc2  ? SORT_TDC2(preprocess_out.preprocessed)  : null
    sort_lupin_out = params.run_lupin ? SORT_LUPIN(preprocess_out.preprocessed) : null

    // ── Per-sorter channels (empty when toggled off) ────────────────────
    ks4_sorter_ch   = sort_ks4_individual
    sc2_sorter_ch   = params.run_sc2   ? sort_sc2_out.sorter   : Channel.empty()
    tdc2_sorter_ch  = params.run_tdc2  ? sort_tdc2_out.sorter  : Channel.empty()
    lupin_sorter_ch = params.run_lupin ? sort_lupin_out.sorter : Channel.empty()

    // ── COMPARE (raw): all sorter_* folders grouped ─────────────────────
    all_sorters = ks4_sorter_ch
        .mix(sc2_sorter_ch, tdc2_sorter_ch, lupin_sorter_ch)
        .groupTuple(by: [0, 1, 2])

    compare_out = COMPARE(all_sorters)

    // ── ANALYZE: per-sorter processes with different resource allocations ─
    if (params.run_ks4) {
        analyze_ks4_in = preprocess_out.preprocessed
            .combine(sort_ks4_individual, by: [0, 1, 2])
        analyze_ks4_out = ANALYZE_KS4(analyze_ks4_in)
    }
    ks4_analyzer_ch = params.run_ks4 ? analyze_ks4_out.analyzer : Channel.empty()

    if (params.run_sc2) {
        analyze_sc2_in = preprocess_out.preprocessed
            .combine(sort_sc2_out.sorter, by: [0, 1, 2])
        analyze_sc2_out = ANALYZE_SC2(analyze_sc2_in)
    }
    sc2_analyzer_ch = params.run_sc2 ? analyze_sc2_out.analyzer : Channel.empty()

    if (params.run_tdc2) {
        analyze_tdc2_in = preprocess_out.preprocessed
            .combine(sort_tdc2_out.sorter, by: [0, 1, 2])
        analyze_tdc2_out = ANALYZE_TDC2(analyze_tdc2_in)
    }
    tdc2_analyzer_ch = params.run_tdc2 ? analyze_tdc2_out.analyzer : Channel.empty()

    if (params.run_lupin) {
        analyze_lupin_in = preprocess_out.preprocessed
            .combine(sort_lupin_out.sorter, by: [0, 1, 2])
        analyze_lupin_out = ANALYZE_LUPIN(analyze_lupin_in)
    }
    lupin_analyzer_ch = params.run_lupin ? analyze_lupin_out.analyzer : Channel.empty()

    // ── ADVANCED_CURATE: per-sorter (parallel) ──────────────────────────
    // Produces clean sortings (noise removed + merged) + label JSONs.
    all_analyze_non_lupin = ks4_analyzer_ch
        .mix(sc2_analyzer_ch, tdc2_analyzer_ch)

    adv_curate_in = preprocess_out.preprocessed
        .combine(all_analyze_non_lupin, by: [0, 1, 2])
    adv_curate_out = ADVANCED_CURATE(adv_curate_in)

    if (params.run_lupin) {
        adv_curate_lupin_in = preprocess_out.preprocessed
            .combine(lupin_analyzer_ch, by: [0, 1, 2])
        adv_curate_lupin_out = ADV_CURATE_LPN(adv_curate_lupin_in)
    }
    lupin_clean_ch     = params.run_lupin ? adv_curate_lupin_out.clean_sorting : Channel.empty()
    lupin_adv_labels_ch = params.run_lupin ? adv_curate_lupin_out.adv_labels   : Channel.empty()

    // ── COMPARE_CLEAN: all sorting_clean_* folders grouped ──────────────
    all_clean = adv_curate_out.clean_sorting
        .mix(lupin_clean_ch)
        .groupTuple(by: [0, 1, 2])
    compare_clean_out = COMPARE_CLEAN(all_clean)

    // ── CONSENSUS_DELTA: compare raw vs clean consensus ─────────────────
    delta_in = compare_out.consensus
        .join(compare_clean_out.consensus_clean, by: [0, 1, 2])
    CONSENSUS_DELTA(delta_in)

    // ── CURATE: merges all labels + both consensuses ────────────────────
    all_analyzers = ks4_analyzer_ch
        .mix(sc2_analyzer_ch, tdc2_analyzer_ch, lupin_analyzer_ch)
        .groupTuple(by: [0, 1, 2])

    all_adv_labels = adv_curate_out.adv_labels
        .mix(lupin_adv_labels_ch)
        .groupTuple(by: [0, 1, 2])

    curate_in = all_analyzers
        .join(compare_out.consensus, by: [0, 1, 2])
        .join(compare_clean_out.consensus_clean, by: [0, 1, 2])
        .join(all_adv_labels, by: [0, 1, 2])
    curate_out = CURATE(curate_in)

    // ── NWB_EXPORT (optional): 05-export-nwb.py discovers curation_*.json
    if (params.run_nwb_export) {
        nwb_in = preprocess_out.preprocessed
            .join(all_sorters, by: [0, 1, 2])
            .join(curate_out.curation, by: [0, 1, 2])
        NWB_EXPORT(nwb_in)
    }
}

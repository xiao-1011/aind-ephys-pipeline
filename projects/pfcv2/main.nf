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
        .
    """
}

process SORT_KS4 {
    tag "${sid}/${probe}"

    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(duration_minutes), path('preprocessed')

    output:
    tuple val(sid), val(probe), val(duration_minutes), path('sorter_kilosort4'), emit: sorter

    script:
    """
    python ${projectDir}/scripts/02-sort.py \\
        . \\
        --sorters kilosort4
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

process SORT_MS5 {
    tag "${sid}/${probe}"
    errorStrategy 'ignore'

    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(duration_minutes), path('preprocessed')

    output:
    tuple val(sid), val(probe), val(duration_minutes), path('sorter_mountainsort5'), emit: sorter

    script:
    """
    python ${projectDir}/scripts/02-sort.py \\
        . \\
        --sorters mountainsort5
    """
}

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

// ANALYZE runs per-sorter (one SLURM job each) instead of one serial job for
// all sorters. Same core-hours, ~4x faster wall-clock, smaller memory footprint.
// The script already supports --sorter_folder for single-sorter mode.
// To revert to serial: restore main.nf.bak + nextflow.config.bak, or
// remove --sorter_folder and change input to path(sorter_dirs) with groupTuple.
process ANALYZE {
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
//   PREPROCESS
//     ├─→ SORT_KS4   (GPU) ──→ ┐
//     ├─→ SORT_SC2   (CPU) ──→ ├──→ COMPARE (raw) ───────────────────────────────→ ┐
//     ├─→ SORT_MS5   (CPU) ──→ ├──→ ┐                                               │
//     ├─→ SORT_TDC2  (CPU) ──→ ┤    ├──→ ANALYZE      ──→ ADVANCED_CURATE ──→ ┐    │
//     └─→ SORT_LUPIN (CPU) ──→ ┘    └──→ ANALYZE_LUPIN ──→ ADV_CURATE_LPN ──→ ├→ COMPARE_CLEAN ─→ ┐
//                                                                              │    │                │
//                                                                              │    └─→ CONSENSUS_DELTA
//                                                                              │                     │
//                                                                              └───→ CURATE ←────────┘
//                                                                                      │
//                                                                                [NWB_EXPORT]
//
// ANALYZE runs one SLURM job per sorter (4-5 parallel jobs per probe).
// ADVANCED_CURATE removes redundant/noise units, merges splits, labels with
// bombcell + UnitRefine. Produces clean sortings for COMPARE_CLEAN.
// CONSENSUS_DELTA compares raw vs clean consensus (delta plots + summary).
//
// Optional sorters (MS5, TDC2, Lupin) use errorStrategy 'ignore' — if they
// fail, the pipeline continues with whichever sorters succeeded.
//
// NWB_EXPORT is off by default (params.run_nwb_export).
// SLURM time allocations scale with recording duration (parsed from .ap.meta).
// ─────────────────────────────────────────────────────────────────────────────

workflow {

    probes_ch = discoverProbes()
    probes_ch.view { sid, probe, dur, _ -> "Discovered probe: ${sid}/${probe} (${dur} min)" }

    preprocess_out = PREPROCESS(probes_ch)

    // All five sorters run in parallel on the same preprocessed recording
    sort_ks4_out   = SORT_KS4(preprocess_out.preprocessed)
    sort_sc2_out   = SORT_SC2(preprocess_out.preprocessed)
    sort_ms5_out   = SORT_MS5(preprocess_out.preprocessed)
    sort_tdc2_out  = SORT_TDC2(preprocess_out.preprocessed)
    sort_lupin_out = SORT_LUPIN(preprocess_out.preprocessed)

    // ── COMPARE (raw): all sorter_* folders grouped ─────────────────────
    all_sorters = sort_ks4_out.sorter
        .mix(sort_sc2_out.sorter, sort_ms5_out.sorter, sort_tdc2_out.sorter, sort_lupin_out.sorter)
        .groupTuple(by: [0, 1, 2])

    compare_out = COMPARE(all_sorters)

    // ── ANALYZE: one SLURM job per sorter (parallel) ────────────────────
    all_sorter_individual = sort_ks4_out.sorter
        .mix(sort_sc2_out.sorter, sort_ms5_out.sorter, sort_tdc2_out.sorter)

    analyze_in = preprocess_out.preprocessed
        .combine(all_sorter_individual, by: [0, 1, 2])
    analyze_out = ANALYZE(analyze_in)

    analyze_lupin_in = preprocess_out.preprocessed
        .combine(sort_lupin_out.sorter, by: [0, 1, 2])
    analyze_lupin_out = ANALYZE_LUPIN(analyze_lupin_in)

    // ── ADVANCED_CURATE: per-sorter (parallel) ──────────────────────────
    // Produces clean sortings (noise removed + merged) + label JSONs.
    adv_curate_in = preprocess_out.preprocessed
        .combine(analyze_out.analyzer, by: [0, 1, 2])
    adv_curate_out = ADVANCED_CURATE(adv_curate_in)

    adv_curate_lupin_in = preprocess_out.preprocessed
        .combine(analyze_lupin_out.analyzer, by: [0, 1, 2])
    adv_curate_lupin_out = ADV_CURATE_LPN(adv_curate_lupin_in)

    // ── COMPARE_CLEAN: all sorting_clean_* folders grouped ──────────────
    all_clean = adv_curate_out.clean_sorting
        .mix(adv_curate_lupin_out.clean_sorting)
        .groupTuple(by: [0, 1, 2])
    compare_clean_out = COMPARE_CLEAN(all_clean)

    // ── CONSENSUS_DELTA: compare raw vs clean consensus ─────────────────
    delta_in = compare_out.consensus
        .join(compare_clean_out.consensus_clean, by: [0, 1, 2])
    CONSENSUS_DELTA(delta_in)

    // ── CURATE: merges all labels + both consensuses ────────────────────
    all_analyzers = analyze_out.analyzer
        .mix(analyze_lupin_out.analyzer)
        .groupTuple(by: [0, 1, 2])

    all_adv_labels = adv_curate_out.adv_labels
        .mix(adv_curate_lupin_out.adv_labels)
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

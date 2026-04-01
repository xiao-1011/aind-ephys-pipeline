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

process CURATE {
    tag "${sid}/${probe}"

    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(duration_minutes), path(analyzer_dirs), path('consensus_labels.json')

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
//     ├─→ SORT_KS4   (GPU, required) ─→ ANALYZE       ─→ ┐
//     ├─→ SORT_SC2   (CPU, required) ─→ ANALYZE       ─→ ┤
//     ├─→ SORT_MS5   (CPU, optional) ─→ ANALYZE       ─→ ┤─→ CURATE ─→ [NWB_EXPORT]
//     ├─→ SORT_TDC2  (CPU, optional) ─→ ANALYZE       ─→ ┤
//     └─→ SORT_LUPIN (CPU, optional) ─→ ANALYZE_LUPIN ─→ ┘
//                                   └─→ COMPARE ──────────┘
//
// ANALYZE runs one SLURM job per sorter (4-5 parallel jobs per probe).
// ANALYZE_LUPIN uses a separate container (SI 0.104.0) to read lupin output.
//
// Optional sorters (MS5, TDC2, Lupin) use errorStrategy 'ignore' — if they
// fail, the pipeline continues with whichever sorters succeeded.
//
// NWB_EXPORT is off by default (params.run_nwb_export). Enable for automatic
// export of auto-curated units. Manual curation typically precedes final NWB.
//
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

    // ── COMPARE: needs all sorters grouped ──────────────────────────────
    // Collect all successful sorter outputs per probe for comparison.
    // Failed sorters (errorStrategy 'ignore') simply don't emit.
    // Uses lupin container (SI 0.104.0) which can read all sorter formats.
    all_sorters = sort_ks4_out.sorter
        .mix(sort_sc2_out.sorter, sort_ms5_out.sorter, sort_tdc2_out.sorter, sort_lupin_out.sorter)
        .groupTuple(by: [0, 1, 2])

    compare_out = COMPARE(all_sorters)

    // ── ANALYZE: one SLURM job per sorter (parallel) ────────────────────
    // Non-lupin sorters use base container (SI 0.103.0).
    // Lupin uses ANALYZE_LUPIN with lupin container (SI 0.104.0).
    all_sorter_individual = sort_ks4_out.sorter
        .mix(sort_sc2_out.sorter, sort_ms5_out.sorter, sort_tdc2_out.sorter)

    analyze_in = preprocess_out.preprocessed
        .combine(all_sorter_individual, by: [0, 1, 2])
    analyze_out = ANALYZE(analyze_in)

    analyze_lupin_in = preprocess_out.preprocessed
        .combine(sort_lupin_out.sorter, by: [0, 1, 2])
    analyze_lupin_out = ANALYZE_LUPIN(analyze_lupin_in)

    // Merge all analyzer outputs per probe for downstream steps
    all_analyzers = analyze_out.analyzer
        .mix(analyze_lupin_out.analyzer)
        .groupTuple(by: [0, 1, 2])

    // ── CURATE: 04-curate.py discovers all analyzer_* dirs automatically
    curate_in = all_analyzers
        .join(compare_out.consensus, by: [0, 1, 2])
    curate_out = CURATE(curate_in)

    // ── NWB_EXPORT (optional): 05-export-nwb.py discovers curation_*.json
    if (params.run_nwb_export) {
        nwb_in = preprocess_out.preprocessed
            .join(all_sorters, by: [0, 1, 2])
            .join(curate_out.curation, by: [0, 1, 2])
        NWB_EXPORT(nwb_in)
    }
}

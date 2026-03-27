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
// The channel emits: (session_name, probe_name, probe_dir_path)
// ─────────────────────────────────────────────────────────────────────────────

def discoverProbes() {
    Channel
        .fromPath("${params.data_path}/**/*.ap.meta")
        .map  { meta -> meta.parent }
        .unique()
        .map  { probe_dir ->
            def session = probe_dir.parent.name
            def probe   = probe_dir.name
            tuple(session, probe, probe_dir)
        }
}

// ─────────────────────────────────────────────────────────────────────────────
// Processes
// ─────────────────────────────────────────────────────────────────────────────

process PREPROCESS {
    tag "${session}/${probe}"

    publishDir "${params.results_path}/${session}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(session), val(probe), path(probe_dir)

    output:
    tuple val(session), val(probe), path('preprocessed'), emit: preprocessed
    path 'motion_*',                                      emit: motion, optional: true

    script:
    """
    python ${projectDir}/scripts/01-preprocess.py \\
        ${probe_dir} \\
        .
    """
}

process SORT_KS4 {
    tag "${session}/${probe}"

    publishDir "${params.results_path}/${session}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(session), val(probe), path('preprocessed')

    output:
    tuple val(session), val(probe), path('sorter_kilosort4'), emit: sorter

    script:
    """
    python ${projectDir}/scripts/02-sort.py \\
        . \\
        --sorters kilosort4
    """
}

process SORT_SC2 {
    tag "${session}/${probe}"

    publishDir "${params.results_path}/${session}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(session), val(probe), path('preprocessed')

    output:
    tuple val(session), val(probe), path('sorter_spykingcircus2'), emit: sorter

    script:
    """
    python ${projectDir}/scripts/02-sort.py \\
        . \\
        --sorters spykingcircus2
    """
}

process COMPARE {
    tag "${session}/${probe}"

    publishDir "${params.results_path}/${session}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    // Both sorter dirs staged by name — 06-compare.py loads them from ./sorter_*/
    tuple val(session), val(probe), path('sorter_kilosort4'), path('sorter_spykingcircus2')

    output:
    tuple val(session), val(probe), path('consensus_labels.json'), emit: consensus

    script:
    """
    python ${projectDir}/scripts/06-compare.py \\
        . \\
        --agreement-threshold ${params.consensus_agreement_threshold}
    """
}

process ANALYZE {
    tag "${session}/${probe}"

    publishDir "${params.results_path}/${session}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    // All three dirs staged by name — 03-analyze.py discovers sorter_* and loads ./preprocessed/
    tuple val(session), val(probe),
          path('preprocessed'), path('sorter_kilosort4'), path('sorter_spykingcircus2')

    output:
    tuple val(session), val(probe),
          path('analyzer_kilosort4'), path('analyzer_spykingcircus2'), emit: analyzers

    script:
    """
    python ${projectDir}/scripts/03-analyze.py .
    """
}

process CURATE {
    tag "${session}/${probe}"

    publishDir "${params.results_path}/${session}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    // analyzer dirs + consensus labels all staged in work dir
    tuple val(session), val(probe),
          path('analyzer_kilosort4'), path('analyzer_spykingcircus2'),
          path('consensus_labels.json')

    output:
    tuple val(session), val(probe),
          path('curation_kilosort4.json'), path('curation_spykingcircus2.json'), emit: curation

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
    tag "${session}/${probe}"

    publishDir "${params.results_path}/${session}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    // preprocessed/ → recording (channel map, sampling rate)
    // sorter_*/     → spike trains
    // curation_*.json → quality metrics + labels + consensus flags
    tuple val(session), val(probe),
          path('preprocessed'),
          path('sorter_kilosort4'), path('sorter_spykingcircus2'),
          path('curation_kilosort4.json'), path('curation_spykingcircus2.json')

    output:
    tuple val(session), val(probe), path('*.nwb'), emit: nwb

    script:
    """
    python ${projectDir}/scripts/05-export-nwb.py \\
        . \\
        --session-id ${session} \\
        --probe-id   ${probe}
    """
}

// ─────────────────────────────────────────────────────────────────────────────
// Workflow
//
// DAG (per probe, all parallel across probes):
//
//   PREPROCESS
//     ├─→ SORT_KS4 (GPU) ─→ ┬─→ COMPARE (CPU) ─→ ┐
//     └─→ SORT_SC2 (CPU) ─→ ┘                     │
//                            └─→ ANALYZE (CPU) ─→ CURATE ─→ NWB_EXPORT
// ─────────────────────────────────────────────────────────────────────────────

workflow {

    probes_ch = discoverProbes()
    probes_ch.view { session, probe, _ -> "Discovered probe: ${session}/${probe}" }

    preprocess_out = PREPROCESS(probes_ch)
    // emits: preprocessed → (session, probe, preprocessed/)

    // Both sorters run in parallel on the same preprocessed recording
    sort_ks4_out = SORT_KS4(preprocess_out.preprocessed)
    sort_sc2_out = SORT_SC2(preprocess_out.preprocessed)
    // each emits: sorter → (session, probe, sorter_*/)

    // COMPARE runs as soon as both sorters finish (parallel with ANALYZE)
    compare_in = sort_ks4_out.sorter
        .join(sort_sc2_out.sorter, by: [0, 1])
    compare_out = COMPARE(compare_in)
    // emits: consensus → (session, probe, consensus_labels.json)

    // ANALYZE also needs both sorters + preprocessed recording
    analyze_in = preprocess_out.preprocessed
        .join(sort_ks4_out.sorter, by: [0, 1])
        .join(sort_sc2_out.sorter, by: [0, 1])
    analyze_out = ANALYZE(analyze_in)
    // emits: analyzers → (session, probe, analyzer_kilosort4/, analyzer_spykingcircus2/)

    // CURATE waits for ANALYZE (quality metrics) and COMPARE (consensus flags)
    curate_in = analyze_out.analyzers
        .join(compare_out.consensus, by: [0, 1])
    curate_out = CURATE(curate_in)
    // emits: curation → (session, probe, curation_kilosort4.json, curation_spykingcircus2.json)

    // NWB_EXPORT assembles all outputs for the final files
    nwb_in = preprocess_out.preprocessed
        .join(sort_ks4_out.sorter,  by: [0, 1])
        .join(sort_sc2_out.sorter,  by: [0, 1])
        .join(curate_out.curation,  by: [0, 1])
    NWB_EXPORT(nwb_in)
}

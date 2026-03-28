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

process SORT_IRONCLUST {
    tag "${session}/${probe}"
    errorStrategy 'ignore'

    publishDir "${params.results_path}/${session}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(session), val(probe), path('preprocessed')

    output:
    tuple val(session), val(probe), path('sorter_ironclust'), emit: sorter

    script:
    """
    python ${projectDir}/scripts/02-sort.py \\
        . \\
        --sorters ironclust
    """
}

process SORT_YASS {
    tag "${session}/${probe}"
    errorStrategy 'ignore'

    publishDir "${params.results_path}/${session}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(session), val(probe), path('preprocessed')

    output:
    tuple val(session), val(probe), path('sorter_yass'), emit: sorter

    script:
    """
    python ${projectDir}/scripts/02-sort.py \\
        . \\
        --sorters yass
    """
}

process COMPARE {
    tag "${session}/${probe}"

    publishDir "${params.results_path}/${session}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(session), val(probe), path(sorter_dirs)

    output:
    tuple val(session), val(probe), path('consensus_labels.json'), emit: consensus

    script:
    """
    python ${projectDir}/scripts/06-compare.py \\
        . \\
        --agreement-threshold ${params.consensus_agreement_threshold} \\
        --min-agreement       ${params.consensus_min_agreement}
    """
}

process ANALYZE {
    tag "${session}/${probe}"

    publishDir "${params.results_path}/${session}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(session), val(probe), path('preprocessed'), path(sorter_dirs)

    output:
    tuple val(session), val(probe), path('analyzer_*'), emit: analyzers

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
    tuple val(session), val(probe), path(analyzer_dirs), path('consensus_labels.json')

    output:
    tuple val(session), val(probe), path('curation_*.json'), emit: curation

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
    tuple val(session), val(probe),
          path('preprocessed'), path(sorter_dirs), path(curation_files)

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
//     ├─→ SORT_KS4       (GPU, required) ─→ ┐
//     ├─→ SORT_SC2       (CPU, required) ─→ ┤─→ COMPARE ─→ ┐
//     ├─→ SORT_IRONCLUST (CPU, optional) ─→ ┤               │
//     └─→ SORT_YASS      (CPU, optional) ─→ ┘               │
//                                            └─→ ANALYZE ─→ CURATE ─→ NWB_EXPORT
//
// IronClust and YASS use errorStrategy 'ignore' — if they fail, the pipeline
// continues with whichever sorters succeeded. The downstream scripts auto-
// discover all sorter_* folders present.
// ─────────────────────────────────────────────────────────────────────────────

workflow {

    probes_ch = discoverProbes()
    probes_ch.view { session, probe, _ -> "Discovered probe: ${session}/${probe}" }

    preprocess_out = PREPROCESS(probes_ch)

    // All four sorters run in parallel on the same preprocessed recording
    sort_ks4_out       = SORT_KS4(preprocess_out.preprocessed)
    sort_sc2_out       = SORT_SC2(preprocess_out.preprocessed)
    sort_ironclust_out = SORT_IRONCLUST(preprocess_out.preprocessed)
    sort_yass_out      = SORT_YASS(preprocess_out.preprocessed)

    // Collect all successful sorter outputs per probe.
    // Failed sorters (errorStrategy 'ignore') simply don't emit — the group
    // contains only the sorters that succeeded.
    all_sorters = sort_ks4_out.sorter
        .mix(sort_sc2_out.sorter, sort_ironclust_out.sorter, sort_yass_out.sorter)
        .groupTuple(by: [0, 1])
    // Emits: (session, probe, [sorter_dir1, sorter_dir2, ...])

    // COMPARE: 06-compare.py discovers all sorter_* dirs automatically
    compare_out = COMPARE(all_sorters)

    // ANALYZE: 03-analyze.py discovers all sorter_* dirs automatically
    analyze_in = preprocess_out.preprocessed
        .join(all_sorters, by: [0, 1])
    analyze_out = ANALYZE(analyze_in)

    // CURATE: 04-curate.py discovers all analyzer_* dirs automatically
    curate_in = analyze_out.analyzers
        .join(compare_out.consensus, by: [0, 1])
    curate_out = CURATE(curate_in)

    // NWB_EXPORT: 05-export-nwb.py discovers all curation_*.json files automatically
    nwb_in = preprocess_out.preprocessed
        .join(all_sorters, by: [0, 1])
        .join(curate_out.curation, by: [0, 1])
    NWB_EXPORT(nwb_in)
}

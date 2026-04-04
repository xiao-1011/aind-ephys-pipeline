#!/usr/bin/env nextflow
nextflow.enable.dsl = 2

// ---------------------------------------------------------------------------
// Input channel
//
// Accepts two layouts:
//   --data_path /sessions_parent/          -> discovers all sessions and probes
//   --data_path /sessions_parent/session1/ -> single session, all probes
//
// A SpikeGLX probe directory is identified by the presence of *.ap.meta files.
// Recording duration is parsed from the .meta file (fileTimeSecs field) and
// threaded through all processes for dynamic SLURM time allocation.
//
// The channel emits: (session_name, probe_name, duration_minutes, probe_dir_path)
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Processes
//
// All tuples carry: (sid, probe, shank, duration_minutes, ...)
// The shank dimension is added by a flatMap after PREPROCESS.
// ---------------------------------------------------------------------------

process PREPROCESS {
    tag "${sid}/${probe}"

    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(duration_minutes), path(probe_dir)

    output:
    tuple val(sid), val(probe), val(duration_minutes), path('preprocessed_shank*'), emit: preprocessed
    path 'motion_*',                                                                 emit: motion, optional: true

    script:
    """
    python ${projectDir}/scripts/01-preprocess.py \\
        ${probe_dir} \\
        . \\
        --filter-type ${params.filter_type} \\
        ${params.use_spatial_filter ? '--spatial-filter' : '--no-spatial-filter'} \\
        ${params.apply_motion_correction ? '--apply-motion' : '--no-apply-motion'} \\
        ${params.test_duration_sec > 0 ? "--max-duration-sec ${params.test_duration_sec}" : ''}
    """
}

// SORT_KS4_BATCH: batch all shanks onto a single GPU node (4 GPUs).
// Each shank gets its own GPU via CUDA_VISIBLE_DEVICES. This saves 4x GPU
// allocation vs. 4 separate exclusive GPU node jobs.
// Input tuple: (sid, probe, [shanks], dur, [preproc_dirs]) — grouped by probe.
// Output: per-shank sorter_kilosort4 dirs under shank*/ subdirectories.
process SORT_KS4_BATCH {
    tag "${sid}/${probe}"

    publishDir "${params.results_path}/${sid}/${probe}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(shanks), val(duration_minutes), path(preproc_dirs)

    output:
    tuple val(sid), val(probe), val(shanks), val(duration_minutes),
          path('*/sorter_kilosort4'), emit: sorters

    script:
    def n = shanks.size()
    """
    # Set up per-shank work directories with preprocessed symlinks
    SHANKS=(${shanks.join(' ')})
    DIRS=(${preproc_dirs.collect { it.name }.join(' ')})

    for i in \$(seq 0 \$((${n} - 1))); do
        mkdir -p \${SHANKS[\$i]}
        ln -s \$(readlink -f \${DIRS[\$i]}) \${SHANKS[\$i]}/preprocessed
    done

    # Run all sorts in parallel — one GPU per shank
    pids=()
    for i in \$(seq 0 \$((${n} - 1))); do
        CUDA_VISIBLE_DEVICES=\$i python ${projectDir}/scripts/02-sort.py \\
            \${SHANKS[\$i]} --sorters kilosort4 &
        pids+=(\$!)
    done

    # Wait for all — fail if any fail
    for pid in "\${pids[@]}"; do
        wait \$pid
    done
    """
}

process SORT_SC2 {
    tag "${sid}/${probe}/${shank}"

    publishDir "${params.results_path}/${sid}/${probe}/${shank}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path(preproc_dir, stageAs: 'preprocessed')

    output:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path('sorter_spykingcircus2'), emit: sorter

    script:
    """
    python ${projectDir}/scripts/02-sort.py \\
        . \\
        --sorters spykingcircus2
    """
}

process SORT_MS5 {
    tag "${sid}/${probe}/${shank}"
    errorStrategy 'ignore'

    publishDir "${params.results_path}/${sid}/${probe}/${shank}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path(preproc_dir, stageAs: 'preprocessed')

    output:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path('sorter_mountainsort5'), emit: sorter

    script:
    """
    python ${projectDir}/scripts/02-sort.py \\
        . \\
        --sorters mountainsort5
    """
}

process SORT_TDC2 {
    tag "${sid}/${probe}/${shank}"
    errorStrategy 'ignore'

    publishDir "${params.results_path}/${sid}/${probe}/${shank}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path(preproc_dir, stageAs: 'preprocessed')

    output:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path('sorter_tridesclous2'), emit: sorter

    script:
    """
    python ${projectDir}/scripts/02-sort.py \\
        . \\
        --sorters tridesclous2
    """
}

process SORT_LUPIN {
    tag "${sid}/${probe}/${shank}"
    errorStrategy 'ignore'

    publishDir "${params.results_path}/${sid}/${probe}/${shank}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path(preproc_dir, stageAs: 'preprocessed')

    output:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path('sorter_lupin'), emit: sorter

    script:
    """
    python ${projectDir}/scripts/02-sort.py \\
        . \\
        --sorters lupin
    """
}

process COMPARE {
    tag "${sid}/${probe}/${shank}"

    publishDir "${params.results_path}/${sid}/${probe}/${shank}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(shank), val(duration_minutes), path(sorter_dirs)

    output:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path('consensus_labels.json'), emit: consensus
    path 'consensus_plots',              emit: plots, optional: true

    script:
    """
    python ${projectDir}/scripts/06-compare.py \\
        . \\
        --agreement-threshold ${params.consensus_agreement_threshold} \\
        --min-agreement       ${params.consensus_min_agreement}
    """
}

process ANALYZE_KS4 {
    tag "${sid}/${probe}/${shank}/${sorter_dir.name}"

    publishDir "${params.results_path}/${sid}/${probe}/${shank}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path(preproc_dir, stageAs: 'preprocessed'), path(sorter_dir)

    output:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path('analyzer_*'), emit: analyzer

    script:
    """
    python ${projectDir}/scripts/03-analyze.py . --sorter_folder ${sorter_dir}
    """
}

process ANALYZE_SC2 {
    tag "${sid}/${probe}/${shank}/${sorter_dir.name}"

    publishDir "${params.results_path}/${sid}/${probe}/${shank}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path(preproc_dir, stageAs: 'preprocessed'), path(sorter_dir)

    output:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path('analyzer_*'), emit: analyzer

    script:
    """
    python ${projectDir}/scripts/03-analyze.py . --sorter_folder ${sorter_dir}
    """
}

process ANALYZE_TDC2 {
    tag "${sid}/${probe}/${shank}/${sorter_dir.name}"

    publishDir "${params.results_path}/${sid}/${probe}/${shank}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path(preproc_dir, stageAs: 'preprocessed'), path(sorter_dir)

    output:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path('analyzer_*'), emit: analyzer

    script:
    """
    python ${projectDir}/scripts/03-analyze.py . --sorter_folder ${sorter_dir}
    """
}

process ANALYZE_MS5 {
    tag "${sid}/${probe}/${shank}/${sorter_dir.name}"

    publishDir "${params.results_path}/${sid}/${probe}/${shank}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path(preproc_dir, stageAs: 'preprocessed'), path(sorter_dir)

    output:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path('analyzer_*'), emit: analyzer

    script:
    """
    python ${projectDir}/scripts/03-analyze.py . --sorter_folder ${sorter_dir}
    """
}

process ANALYZE_LUPIN {
    tag "${sid}/${probe}/${shank}/${sorter_dir.name}"

    publishDir "${params.results_path}/${sid}/${probe}/${shank}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path(preproc_dir, stageAs: 'preprocessed'), path(sorter_dir)

    output:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path('analyzer_*'), emit: analyzer

    script:
    """
    python ${projectDir}/scripts/03-analyze.py . --sorter_folder ${sorter_dir}
    """
}

process ADVANCED_CURATE {
    tag "${sid}/${probe}/${shank}/${analyzer_dir.name}"

    publishDir "${params.results_path}/${sid}/${probe}/${shank}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path(preproc_dir, stageAs: 'preprocessed'), path(analyzer_dir)

    output:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path('sorting_clean_*'),              emit: clean_sorting
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path('advanced_curation_*.json'),     emit: adv_labels
    path(analyzer_dir)  // re-publish with bombcell/unitrefine/passing_qc JSONs

    script:
    """
    python ${projectDir}/scripts/07-advanced-curate.py . --analyzer_folder ${analyzer_dir}
    """
}

process ADV_CURATE_LPN {
    tag "${sid}/${probe}/${shank}/${analyzer_dir.name}"

    publishDir "${params.results_path}/${sid}/${probe}/${shank}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path(preproc_dir, stageAs: 'preprocessed'), path(analyzer_dir)

    output:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path('sorting_clean_*'),              emit: clean_sorting
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path('advanced_curation_*.json'),     emit: adv_labels
    path(analyzer_dir)  // re-publish with bombcell/unitrefine/passing_qc JSONs

    script:
    """
    python ${projectDir}/scripts/07-advanced-curate.py . --analyzer_folder ${analyzer_dir}
    """
}

process COMPARE_CLEAN {
    tag "${sid}/${probe}/${shank}"
    errorStrategy 'ignore'

    publishDir "${params.results_path}/${sid}/${probe}/${shank}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(shank), val(duration_minutes), path(clean_dirs)

    output:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
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

process CONSENSUS_DELTA {
    tag "${sid}/${probe}/${shank}"

    publishDir "${params.results_path}/${sid}/${probe}/${shank}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
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
    tag "${sid}/${probe}/${shank}"

    publishDir "${params.results_path}/${sid}/${probe}/${shank}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path(analyzer_dirs), path('consensus_labels.json'),
          path('consensus_clean.json'), path(adv_label_files)

    output:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path('curation_*.json'), emit: curation

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
    tag "${sid}/${probe}/${shank}"

    publishDir "${params.results_path}/${sid}/${probe}/${shank}",
               mode: params.publish_mode, overwrite: true

    input:
    tuple val(sid), val(probe), val(shank), val(duration_minutes),
          path(preproc_dir, stageAs: 'preprocessed'),
          path(sorter_dirs), path(curation_files)

    output:
    tuple val(sid), val(probe), val(shank), path('*.nwb'), emit: nwb

    script:
    """
    python ${projectDir}/scripts/05-export-nwb.py \\
        . \\
        --session-id ${sid} \\
        --probe-id   ${probe}
    """
}

// ---------------------------------------------------------------------------
// Workflow
//
// DAG (per probe per shank, all parallel across probes and shanks):
//
//   PREPROCESS (per probe, outputs preprocessed_shank*)
//     |
//     +-- flatMap (fan out per shank) --+
//                                       |
//     +-- per shank: -------------------+------+
//     |                                        |
//     |  +-- groupTuple (regroup shanks) --+   |
//     |  |                                 |   |
//     |  +--> SORT_KS4_BATCH (1 GPU node,  |   |
//     |       4 GPUs, all shanks parallel)  |   |
//     |  |                                 |   |
//     |  +-- flatMap (fan back per shank) -+   |
//     |       |                                |
//     +--> sort_ks4 ──────────────────────> +  |
//     +--> SORT_SC2   (CPU, per-shank) --> +--> COMPARE (raw) ──────────────────> +
//     +--> SORT_MS5   (CPU, per-shank) --> +-->  +                                |
//     +--> SORT_TDC2  (CPU, per-shank) --> +    +--> ANALYZE_KS4  --> ADV_CURATE --> +
//     +--> SORT_LUPIN (CPU, per-shank) --> +    +--> ANALYZE_SC2  --> ADV_CURATE --> +
//                                               +--> ANALYZE_TDC2 --> ADV_CURATE --> +
//                                               +--> ANALYZE_MS5  --> ADV_CURATE --> +
//                                               +--> ANALYZE_LUPIN --> ADV_LPN   --> +--> COMPARE_CLEAN --> +
//                                                                                   |    |                  |
//                                                                                   |    +--> CONSENSUS_DELTA
//                                                                                   |                       |
//                                                                                   +---> CURATE <----------+
//                                                                                           |
//                                                                                     [NWB_EXPORT]
//
// PREPROCESS outputs preprocessed_shank0/ (and shank1..N for multi-shank).
// flatMap fans out per-shank tuples; CPU sorters run independently per shank.
// KS4 is regrouped per probe so all shanks share one exclusive GPU node (4x savings).
// stageAs:'preprocessed' aliases shank dirs so scripts see ./preprocessed/.
// ---------------------------------------------------------------------------

workflow {

    probes_ch = discoverProbes()
    probes_ch.view { sid, probe, dur, _ -> "Discovered probe: ${sid}/${probe} (${dur} min)" }

    preprocess_out = PREPROCESS(probes_ch)

    // ── Fan out per shank ─────────────────────────────────────────────────
    // PREPROCESS emits preprocessed_shank* (1 dir for single-shank, N for multi).
    // flatMap splits into per-shank tuples: (sid, probe, shank, dur, shank_dir)
    shank_ch = preprocess_out.preprocessed
        .flatMap { sid, probe, dur, dirs ->
            def dir_list = (dirs instanceof List) ? dirs : [dirs]
            dir_list.collect { dir ->
                def shank = dir.name.replace('preprocessed_', '')
                tuple(sid, probe, shank, dur, dir)
            }
        }

    shank_ch.view { sid, probe, shank, dur, _ ->
        "  Shank: ${sid}/${probe}/${shank} (${dur} min)"
    }

    // ── KS4: batch all shanks onto 1 GPU node (4 GPUs) ────────────────
    // Regroup shanks by probe so all run on a single exclusive GPU node.
    // groupTuple by (sid[0], probe[1], dur[3]) → shanks[2] and dirs[4] become lists.
    ks4_batch_in = shank_ch
        .groupTuple(by: [0, 1, 3])

    sort_ks4_batch_out = SORT_KS4_BATCH(ks4_batch_in)

    // Fan back to per-shank tuples for downstream compatibility
    sort_ks4_shank = sort_ks4_batch_out.sorters
        .flatMap { sid, probe, shanks, dur, sorter_dirs ->
            def dir_list = (sorter_dirs instanceof List) ? sorter_dirs : [sorter_dirs]
            dir_list.collect { dir ->
                def shank = dir.parent.name   // "shank0", "shank1", etc.
                tuple(sid, probe, shank, dur, dir)
            }
        }

    // CPU sorters run per-shank (individual SLURM jobs)
    sort_sc2_out   = SORT_SC2(shank_ch)
    sort_ms5_out   = SORT_MS5(shank_ch)
    sort_tdc2_out  = SORT_TDC2(shank_ch)
    sort_lupin_out = SORT_LUPIN(shank_ch)

    // ── COMPARE (raw): all sorter_* folders grouped per shank ─────────
    all_sorters = sort_ks4_shank
        .mix(sort_sc2_out.sorter, sort_ms5_out.sorter, sort_tdc2_out.sorter, sort_lupin_out.sorter)
        .groupTuple(by: [0, 1, 2, 3])

    compare_out = COMPARE(all_sorters)

    // ── ANALYZE: per-sorter processes for right-sized resource allocation ──
    analyze_ks4_in = shank_ch
        .combine(sort_ks4_shank, by: [0, 1, 2, 3])
    analyze_ks4_out = ANALYZE_KS4(analyze_ks4_in)

    analyze_sc2_in = shank_ch
        .combine(sort_sc2_out.sorter, by: [0, 1, 2, 3])
    analyze_sc2_out = ANALYZE_SC2(analyze_sc2_in)

    analyze_tdc2_in = shank_ch
        .combine(sort_tdc2_out.sorter, by: [0, 1, 2, 3])
    analyze_tdc2_out = ANALYZE_TDC2(analyze_tdc2_in)

    analyze_ms5_in = shank_ch
        .combine(sort_ms5_out.sorter, by: [0, 1, 2, 3])
    analyze_ms5_out = ANALYZE_MS5(analyze_ms5_in)

    analyze_lupin_in = shank_ch
        .combine(sort_lupin_out.sorter, by: [0, 1, 2, 3])
    analyze_lupin_out = ANALYZE_LUPIN(analyze_lupin_in)

    // ── ADVANCED_CURATE: per-sorter (parallel) ────────────────────────
    all_analyze_non_lupin = analyze_ks4_out.analyzer
        .mix(analyze_sc2_out.analyzer, analyze_tdc2_out.analyzer, analyze_ms5_out.analyzer)

    adv_curate_in = shank_ch
        .combine(all_analyze_non_lupin, by: [0, 1, 2, 3])
    adv_curate_out = ADVANCED_CURATE(adv_curate_in)

    adv_curate_lupin_in = shank_ch
        .combine(analyze_lupin_out.analyzer, by: [0, 1, 2, 3])
    adv_curate_lupin_out = ADV_CURATE_LPN(adv_curate_lupin_in)

    // ── COMPARE_CLEAN: all sorting_clean_* folders grouped ────────────
    all_clean = adv_curate_out.clean_sorting
        .mix(adv_curate_lupin_out.clean_sorting)
        .groupTuple(by: [0, 1, 2, 3])
    compare_clean_out = COMPARE_CLEAN(all_clean)

    // ── CONSENSUS_DELTA: compare raw vs clean consensus ───────────────
    delta_in = compare_out.consensus
        .join(compare_clean_out.consensus_clean, by: [0, 1, 2, 3])
    CONSENSUS_DELTA(delta_in)

    // ── CURATE: merges all labels + both consensuses ──────────────────
    all_analyzers = analyze_ks4_out.analyzer
        .mix(analyze_sc2_out.analyzer, analyze_tdc2_out.analyzer,
             analyze_ms5_out.analyzer, analyze_lupin_out.analyzer)
        .groupTuple(by: [0, 1, 2, 3])

    all_adv_labels = adv_curate_out.adv_labels
        .mix(adv_curate_lupin_out.adv_labels)
        .groupTuple(by: [0, 1, 2, 3])

    curate_in = all_analyzers
        .join(compare_out.consensus, by: [0, 1, 2, 3])
        .join(compare_clean_out.consensus_clean, by: [0, 1, 2, 3])
        .join(all_adv_labels, by: [0, 1, 2, 3])
    curate_out = CURATE(curate_in)

    // ── NWB_EXPORT (optional) ─────────────────────────────────────────
    if (params.run_nwb_export) {
        nwb_in = shank_ch
            .join(all_sorters, by: [0, 1, 2, 3])
            .join(curate_out.curation, by: [0, 1, 2, 3])
        NWB_EXPORT(nwb_in)
    }
}

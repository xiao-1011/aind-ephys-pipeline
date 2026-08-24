#!/usr/bin/env nextflow
nextflow.enable.dsl = 2

params.ecephys_path = null
params.results_path = null
params.params_file = null
params.executor = 'local'
params.git_repo_prefix = env('GIT_REPO_PREFIX') ?: 'https://github.com/AllenNeuralDynamics/aind-'
params.capsule_versions = "${projectDir}/capsule_versions.env"
params.n_jobs = -1
params.runmode = 'full'
params.sorter = 'kilosort4'
params.job_dispatch_args = ''
params.preprocessing_args = ''
params.spikesorting_args = ''
params.postprocessing_args = ''
params.curation_args = ''
params.visualization_kwargs = ''
params.nwb_subject_args = ''
params.nwb_ecephys_args = ''

def cloneFunctionScript() {
    return '''
clone_repo() {
    local repo_url="$1"
    local commit_hash="$2"

    echo "cloning git repo: \${repo_url} (commit: \${commit_hash})..."

    git clone "\${repo_url}" capsule-repo
    git -C capsule-repo -c core.fileMode=false checkout "\${commit_hash}" --quiet

    mv capsule-repo/code capsule/code
    rm -rf capsule-repo
}
'''
}

def jsonArguments(jsonSection) {
    return jsonSection
        ? "--params '${groovy.json.JsonOutput.toJson(jsonSection)}'"
        : ''
}

def stringParameter(pipelineParams, name) {
    def value = pipelineParams[name]
    return value instanceof String ? value : ''
}

def buildSettings(pipelineParams) {
    def settings = [:]
    settings.data_path = pipelineParams.ecephys_path
    settings.results_path = pipelineParams.results_path
    settings.executor = pipelineParams.executor ?: 'local'
    settings.git_repo_prefix = pipelineParams.git_repo_prefix
    settings.clone_function = cloneFunctionScript()

    def jsonParams = pipelineParams.params_file
        ? new groovy.json.JsonSlurper().parseText(new File(pipelineParams.params_file.toString()).text)
        : [:]

    def versions = [:]
    new File(pipelineParams.capsule_versions.toString()).eachLine { line ->
        def (key, value) = line.tokenize('=')
        versions[key] = value
    }
    settings.versions = versions
    settings.container_tag = "si-${versions['SPIKEINTERFACE_VERSION']}"

    def parameterNames = pipelineParams.keySet()
    def nJobs = parameterNames.contains('n_jobs') ? pipelineParams.n_jobs : -1
    settings.job_args = settings.executor == 'local' ? " --n-jobs ${nJobs}" : ''
    settings.runmode = parameterNames.contains('runmode') ? pipelineParams.runmode : 'full'

    settings.job_dispatch_args = jsonParams.job_dispatch
        ? jsonArguments(jsonParams.job_dispatch)
        : stringParameter(pipelineParams, 'job_dispatch_args')
    settings.preprocessing_args = jsonParams.preprocessing
        ? jsonArguments(jsonParams.preprocessing)
        : stringParameter(pipelineParams, 'preprocessing_args')
    settings.postprocessing_args = jsonParams.postprocessing
        ? jsonArguments(jsonParams.postprocessing)
        : stringParameter(pipelineParams, 'postprocessing_args')
    settings.curation_args = jsonParams.curation
        ? jsonArguments(jsonParams.curation)
        : stringParameter(pipelineParams, 'curation_args')
    settings.visualization_kwargs = jsonParams.visualization
        ? jsonArguments(jsonParams.visualization)
        : stringParameter(pipelineParams, 'visualization_kwargs')
    settings.nwb_subject_args = jsonParams.nwb?.subject
        ? jsonArguments(jsonParams.nwb.subject)
        : stringParameter(pipelineParams, 'nwb_subject_args')
    settings.nwb_ecephys_args = jsonParams.nwb?.ecephys
        ? jsonArguments(jsonParams.nwb.ecephys)
        : stringParameter(pipelineParams, 'nwb_ecephys_args')

    settings.sorter = jsonParams.spikesorting?.sorter
        ?: stringParameter(pipelineParams, 'sorter')
        ?: 'kilosort4'
    def sorterParams = jsonParams.spikesorting
        ? jsonParams.spikesorting[settings.sorter]
        : null
    settings.spikesorting_args = sorterParams
        ? jsonArguments(sorterParams)
        : stringParameter(pipelineParams, 'spikesorting_args')

    if (settings.runmode == 'fast') {
        settings.preprocessing_args = '--motion skip'
        settings.postprocessing_args = '--skip-extensions spike_locations,principal_components'
        settings.nwb_ecephys_args = '--skip-lfp'
    }

    return settings
}

// Process definitions
process job_dispatch {
    tag 'job-dispatch'
    container "ghcr.io/allenneuraldynamics/aind-ephys-pipeline-base:${settings.container_tag}"

    input:
    val settings
    path input_folder, stageAs: 'capsule/data/ecephys_session'
    
    output:
    path 'capsule/results/*', emit: results
    path 'max_duration.txt', emit: max_duration_file  // file containing the value


    script:
    """
    #!/usr/bin/env bash
    set -e

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
    fi

    TASK_DIR=\$(pwd)

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.git_repo_prefix}ephys-job-dispatch.git" "${settings.versions['JOB_DISPATCH']}"

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run ${settings.job_dispatch_args}

    MAX_DURATION_MIN=\$(python get_max_recording_duration_min.py)

    cd \$TASK_DIR
    echo "\$MAX_DURATION_MIN" > max_duration.txt

    echo "[${task.tag}] completed!"

    """
}

process preprocessing {
    tag 'preprocessing'
    container "ghcr.io/allenneuraldynamics/aind-ephys-pipeline-base:${settings.container_tag}"

    input:
    val settings
    val max_duration_minutes
    path ecephys_session_input, stageAs: 'capsule/data/ecephys_session'
    path job_dispatch_results, stageAs: 'capsule/data/*'

    output:
    path 'capsule/results/*', emit: results

    script:
    """
    #!/usr/bin/env bash
    set -e

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.git_repo_prefix}ephys-preprocessing.git" "${settings.versions['PREPROCESSING']}"

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run ${settings.preprocessing_args} ${settings.job_args}

    echo "[${task.tag}] completed!"
    """
}

process spikesort_kilosort25 {
    tag 'spikesort-kilosort25'
    container "ghcr.io/allenneuraldynamics/aind-ephys-spikesort-kilosort25:${settings.container_tag}"

    input:
    val settings
    val max_duration_minutes
    path preprocessing_results, stageAs: 'capsule/data/*'

    output:
    path 'capsule/results/*', emit: results

    script:
    """
    #!/usr/bin/env bash
    set -e

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.git_repo_prefix}ephys-spikesort-kilosort25.git" "${settings.versions['SPIKESORT_KS25']}"

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run ${settings.spikesorting_args} ${settings.job_args}

    echo "[${task.tag}] completed!"
    """
}

process spikesort_kilosort4 {
    tag 'spikesort-kilosort4'
    container "ghcr.io/allenneuraldynamics/aind-ephys-spikesort-kilosort4:${settings.container_tag}"

    input:
    val settings
    val max_duration_minutes
    path preprocessing_results, stageAs: 'capsule/data/*'

    output:
    path 'capsule/results/*', emit: results

    script:
    """
    #!/usr/bin/env bash
    set -e

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.git_repo_prefix}ephys-spikesort-kilosort4.git" "${settings.versions['SPIKESORT_KS4']}"

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run ${settings.spikesorting_args} ${settings.job_args}

    echo "[${task.tag}] completed!"
    """
}

process spikesort_spykingcircus2 {
    tag 'spikesort-spykingcircus2'
    container "ghcr.io/allenneuraldynamics/aind-ephys-pipeline-base:${settings.container_tag}"

    input:
    val settings
    val max_duration_minutes
    path preprocessing_results, stageAs: 'capsule/data/*'

    output:
    path 'capsule/results/*', emit: results

    script:
    """
    #!/usr/bin/env bash
    set -e

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.git_repo_prefix}ephys-spikesort-spykingcircus2.git" "${settings.versions['SPIKESORT_SC2']}"

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run ${settings.spikesorting_args} ${settings.job_args}

    echo "[${task.tag}] completed!"
    """
}

process postprocessing {
    tag 'postprocessing'
    container "ghcr.io/allenneuraldynamics/aind-ephys-pipeline-base:${settings.container_tag}"

    input:
    val settings
    val max_duration_minutes
    path ecephys_session_input, stageAs: 'capsule/data/ecephys_session'
    path job_dispatch_results, stageAs: 'capsule/data/*'
    path preprocessing_results, stageAs: 'capsule/data/*'
    path spikesort_results, stageAs: 'capsule/data/*'

    output:
    path 'capsule/results/*', emit: results

    script:
    """
    #!/usr/bin/env bash
    set -e

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.git_repo_prefix}ephys-postprocessing.git" "${settings.versions['POSTPROCESSING']}"

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run ${settings.postprocessing_args} ${settings.job_args}

    echo "[${task.tag}] completed!"
    """
}

process curation {
    tag 'curation'
    container "ghcr.io/allenneuraldynamics/aind-ephys-pipeline-base:${settings.container_tag}"

    input:
    val settings
    val max_duration_minutes
    path postprocessing_results, stageAs: 'capsule/data/*'

    output:
    path 'capsule/results/*', emit: results

    script:
    """
    #!/usr/bin/env bash
    set -e

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.git_repo_prefix}ephys-curation.git" "${settings.versions['CURATION']}"

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run ${settings.curation_args} ${settings.job_args}

    echo "[${task.tag}] completed!"
    """
}

process visualization {
    tag 'visualization'
    container "ghcr.io/allenneuraldynamics/aind-ephys-pipeline-base:${settings.container_tag}"

    input:
    val settings
    val max_duration_minutes
    path ecephys_session_input, stageAs: 'capsule/data/ecephys_session'
    path job_dispatch_results, stageAs: 'capsule/data/*'
    path preprocessing_results, stageAs: 'capsule/data/*'
    path spikesort_results, stageAs: 'capsule/data/*'
    path postprocessing_results, stageAs: 'capsule/data/*'
    path curation_results, stageAs: 'capsule/data/*'

    output:
    path 'capsule/results/*', emit: results

    script:
    """
    #!/usr/bin/env bash
    set -e

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.git_repo_prefix}ephys-visualization.git" "${settings.versions['VISUALIZATION']}"

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run ${settings.visualization_kwargs}

    echo "[${task.tag}] completed!"
    """
}

process results_collector {
    tag 'result-collector'
    container "ghcr.io/allenneuraldynamics/aind-ephys-pipeline-base:${settings.container_tag}"

    publishDir params.results_path, saveAs: { filename -> new File(filename).getName() }, mode: 'copy'

    input:
    val settings
    val max_duration_minutes
    path ecephys_session_input, stageAs: 'capsule/data/ecephys_session'
    path job_dispatch_results, stageAs: 'capsule/data/*'
    path preprocessing_results, stageAs: 'capsule/data/*'
    path spikesort_results, stageAs: 'capsule/data/*'
    path postprocessing_results, stageAs: 'capsule/data/*'
    path curation_results, stageAs: 'capsule/data/*'
    path visualization_results, stageAs: 'capsule/data/*'

    output:
    path 'capsule/results/*', emit: results
    path 'capsule/results/*', emit: nwb_data
    path 'capsule/results/*', emit: qc_data

    script:
    """
    #!/usr/bin/env bash
    set -e

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.git_repo_prefix}ephys-results-collector.git" "${settings.versions['RESULTS_COLLECTOR']}"

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run --pipeline-data-path ${settings.data_path} --pipeline-results-path ${settings.results_path}

    echo "[${task.tag}] completed!"
    """
}

process quality_control {
    tag 'quality-control'
    container "ghcr.io/allenneuraldynamics/aind-ephys-pipeline-base:${settings.container_tag}"

    input:
    val settings
    val max_duration_minutes
    path ecephys_session_input, stageAs: 'capsule/data/ecephys_session'
    path job_dispatch_results, stageAs: 'capsule/data/*'
    path results_data, stageAs: 'capsule/data/*'

    output:
    path 'capsule/results/*', emit: results

    script:
    """
    #!/usr/bin/env bash
    set -e

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.git_repo_prefix}ephys-processing-qc.git" "${settings.versions['QUALITY_CONTROL']}"

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run

    echo "[${task.tag}] completed!"
    """
}

process quality_control_collector {
    tag 'qc-collector'
    container "ghcr.io/allenneuraldynamics/aind-ephys-pipeline-base:${settings.container_tag}"

    publishDir params.results_path, saveAs: { filename -> new File(filename).getName() }, mode: 'copy'

    input:
    val settings
    val max_duration_minutes
    path quality_control_results, stageAs: 'capsule/data/*'

    output:
    path 'capsule/results/*'

    script:
    """
    #!/usr/bin/env bash
    set -e

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.git_repo_prefix}ephys-qc-collector.git" "${settings.versions['QUALITY_CONTROL_COLLECTOR']}"

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run

    echo "[${task.tag}] completed!"
    """
}

process nwb_subject {
    tag 'nwb-subject'
    container "ghcr.io/allenneuraldynamics/aind-ephys-pipeline-nwb:${settings.container_tag}"

    input:
    val settings
    val max_duration_minutes
    path ecephys_session_input, stageAs: 'capsule/data/ecephys_session'

    output:
    path 'capsule/results/*', emit: results

    script:
    """
    #!/usr/bin/env bash
    set -e

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.git_repo_prefix}subject-nwb.git" "${settings.versions['NWB_SUBJECT']}"

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run ${settings.nwb_subject_args}

    echo "[${task.tag}] completed!"
    """
}

process nwb_ecephys {
    tag 'nwb-ecephys'
    container "ghcr.io/allenneuraldynamics/aind-ephys-pipeline-nwb:${settings.container_tag}"

    input:
    val settings
    val max_duration_minutes
    path ecephys_session_input, stageAs: 'capsule/data/ecephys_session'
    path job_dispatch_results, stageAs: 'capsule/data/*'

    output:
    path 'capsule/results/*', emit: results

    script:
    """
    #!/usr/bin/env bash
    set -e

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.git_repo_prefix}ecephys-nwb.git" "${settings.versions['NWB_ECEPHYS']}"

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run ${settings.nwb_ecephys_args}

    echo "[${task.tag}] completed!"
    """
}

process nwb_units {
    tag 'nwb-units'
    container "ghcr.io/allenneuraldynamics/aind-ephys-pipeline-nwb:${settings.container_tag}"

    publishDir "${params.results_path}/nwb", saveAs: { filename -> new File(filename).getName() }, mode: 'copy'

    input:
    val settings
    val max_duration_minutes
    path ecephys_session_input, stageAs: 'capsule/data/ecephys_session'
    path job_dispatch_results, stageAs: 'capsule/data/*'
    path results_data, stageAs: 'capsule/data/*'
    path nwb_ecephys_results, stageAs: 'capsule/data/*'

    output:
    path 'capsule/results/*'

    script:
    """
    #!/usr/bin/env bash
    set -e

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.git_repo_prefix}units-nwb.git" "${settings.versions['NWB_UNITS']}"

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
    fi

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run

    echo "[${task.tag}] completed!"
    """
}

workflow {
    def settings = buildSettings(params)

    println "DATA_PATH: ${settings.data_path}"
    println "RESULTS_PATH: ${settings.results_path}"
    println "CONTAINER TAG: ${settings.container_tag}"
    println "Using RUNMODE: ${settings.runmode}"
    println "Using SORTER: ${settings.sorter} with args: ${settings.spikesorting_args}"

    // Input channel from ecephys path
    ecephys_ch = channel.fromPath(params.ecephys_path + '/', type: 'any')

    // Job dispatch
    job_dispatch_out = job_dispatch(settings, ecephys_ch.collect())

    max_duration_file = job_dispatch_out.max_duration_file
    max_duration_minutes = max_duration_file.map { durationFile -> durationFile.text.trim() }
    max_duration_minutes.view { duration -> "Max recording duration: ${duration}min" }

    // Preprocessing
    preprocessing_out = preprocessing(
        settings,
        max_duration_minutes,
        ecephys_ch.collect(),
        job_dispatch_out.results.flatten()
    )

    // Spike sorting based on selected sorter
    // def spikesort
    if (settings.sorter == 'kilosort25') {
        spikesort_out = spikesort_kilosort25(
            settings,
            max_duration_minutes,
            preprocessing_out.results
        )
    } else if (settings.sorter == 'kilosort4') {
        spikesort_out = spikesort_kilosort4(
            settings,
            max_duration_minutes,
            preprocessing_out.results
        )
    } else if (settings.sorter == 'spykingcircus2') {
        spikesort_out = spikesort_spykingcircus2(
            settings,
            max_duration_minutes,
            preprocessing_out.results
        )
    } else {
        throw new IllegalArgumentException("Unsupported sorter: ${settings.sorter}")
    }

    // Postprocessing
    postprocessing_out = postprocessing(
        settings,
        max_duration_minutes,
        ecephys_ch.collect(),
        job_dispatch_out.results.flatten(),
        preprocessing_out.results.collect(),
        spikesort_out.results.collect()
    )

    // Curation
    curation_out = curation(
        settings,
        max_duration_minutes,
        postprocessing_out.results
    )

    // Visualization
    visualization_out = visualization(
        settings,
        max_duration_minutes,
        ecephys_ch.collect(),
        job_dispatch_out.results.collect(),
        preprocessing_out.results,
        spikesort_out.results.collect(),
        postprocessing_out.results.collect(),
        curation_out.results.collect()
    )

    // Results collection
    results_collector_out = results_collector(
        settings,
        max_duration_minutes,
        ecephys_ch.collect(),
        job_dispatch_out.results.collect(),
        preprocessing_out.results.collect(),
        spikesort_out.results.collect(),
        postprocessing_out.results.collect(),
        curation_out.results.collect(),
        visualization_out.results.collect()
    )

    // Quality control
    quality_control_out = quality_control(
        settings,
        max_duration_minutes,
        ecephys_ch.collect(),
        job_dispatch_out.results.flatten(),
        results_collector_out.qc_data.collect()
    )

    // Quality control collection
    quality_control_collector(
        settings,
        max_duration_minutes,
        quality_control_out.results.collect()
    )

    // NWB ecephys
    nwb_ecephys_out = nwb_ecephys(
        settings,
        max_duration_minutes,
        ecephys_ch.collect(),
        job_dispatch_out.results.collect()
    )

    // NWB units
    nwb_units(
        settings,
        max_duration_minutes,
        ecephys_ch.collect(),
        job_dispatch_out.results.collect(),
        results_collector_out.nwb_data.collect(),
        nwb_ecephys_out.results.collect()
    )
}

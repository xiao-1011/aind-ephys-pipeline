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

def stringParameter(pipelineParams, name) {
    def value = pipelineParams[name]
    return value instanceof String ? value : ''
}

def buildStepArguments(jsonSection, pipelineParams, cliParameterName) {
    def arguments = jsonSection ? new LinkedHashMap(jsonSection) : [:]
    def cliArguments = stringParameter(pipelineParams, cliParameterName).trim()

    if (cliArguments) {
        cliArguments.split(/\s+(?=--)/).each { segment ->
            def tokens = segment.trim().split(/\s+/, 2)
            if (tokens[0].startsWith('--')) {
                def key = tokens[0].substring(2).replace('-', '_')
                def value = tokens.size() > 1 ? tokens[1] : true
                arguments[key] = value
            }
        }
    }

    return arguments
        ? "--params '${groovy.json.JsonOutput.toJson(arguments)}'"
        : ''
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

    def defaultVersionsFile = new File(pipelineParams.capsule_versions.toString())
    def customVersionsFile = new File(defaultVersionsFile.parent, 'capsule_versions_custom.env')
    def versionsFile = customVersionsFile.exists() ? customVersionsFile : defaultVersionsFile
    def versions = [:]
    versionsFile.eachLine { line ->
        if (line.contains('=')) {
            def separator = line.indexOf('=')
            def key = line.substring(0, separator).trim()
            def value = line.substring(separator + 1).trim().replaceAll("^[\"']|[\"']\$", '')
            versions[key] = value
        }
    }
    settings.versions = versions
    settings.container_tag = "si-${versions['SPIKEINTERFACE_VERSION']}"

    def extraInstalls = versions['EXTRA_INSTALLS'] ?: ''
    def extraInstallList = extraInstalls
        ? extraInstalls.split(',').collect { packageName -> packageName.trim() }.findAll { packageName -> packageName }
        : []
    settings.extra_installs_cmd = extraInstallList
        ? 'pip install ' + extraInstallList.collect { packageName -> "'${packageName}'" }.join(' ')
        : ''
    settings.extra_installs_echo = extraInstallList
        ? "echo 'installing extra packages: ${extraInstallList.join(', ')}'"
        : ''

    def parameterNames = pipelineParams.keySet()
    def nJobs = parameterNames.contains('n_jobs') ? pipelineParams.n_jobs : -1
    settings.job_args = settings.executor == 'local' ? " --n-jobs ${nJobs}" : ''
    settings.runmode = parameterNames.contains('runmode') ? pipelineParams.runmode : 'full'

    settings.job_dispatch_args = buildStepArguments(jsonParams.job_dispatch, pipelineParams, 'job_dispatch_args')
    settings.preprocessing_args = buildStepArguments(jsonParams.preprocessing, pipelineParams, 'preprocessing_args')
    settings.postprocessing_args = buildStepArguments(jsonParams.postprocessing, pipelineParams, 'postprocessing_args')
    settings.curation_args = buildStepArguments(jsonParams.curation, pipelineParams, 'curation_args')
    settings.visualization_kwargs = buildStepArguments(jsonParams.visualization, pipelineParams, 'visualization_kwargs')
    settings.nwb_subject_args = buildStepArguments(jsonParams.nwb?.subject, pipelineParams, 'nwb_subject_args')
    settings.nwb_ecephys_args = buildStepArguments(jsonParams.nwb?.ecephys, pipelineParams, 'nwb_ecephys_args')

    settings.sorter = jsonParams.spikesorting?.sorter
        ?: stringParameter(pipelineParams, 'sorter')
        ?: 'kilosort4'
    def sorterParams = jsonParams.spikesorting
        ? jsonParams.spikesorting[settings.sorter]
        : null
    settings.spikesorting_args = buildStepArguments(sorterParams, pipelineParams, 'spikesorting_args')

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

    ${settings.extra_installs_echo}
    ${settings.extra_installs_cmd}

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
    clone_repo "${settings.versions['JOB_DISPATCH_REPO']}" "${settings.versions['JOB_DISPATCH_COMMIT']}"

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

    ${settings.extra_installs_echo}
    ${settings.extra_installs_cmd}

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
        # Make sure N_JOBS matches allocated CPUs on SLURM
        export N_JOBS_EXT=${task.cpus}
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.versions['PREPROCESSING_REPO']}" "${settings.versions['PREPROCESSING_COMMIT']}"

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
        # Make sure N_JOBS matches allocated CPUs on SLURM
        export N_JOBS_EXT=${task.cpus}
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.versions['SPIKESORT_KS25_REPO']}" "${settings.versions['SPIKESORT_KS25_COMMIT']}"

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
        # Make sure N_JOBS matches allocated CPUs on SLURM
        export N_JOBS_EXT=${task.cpus}
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.versions['SPIKESORT_KS4_REPO']}" "${settings.versions['SPIKESORT_KS4_COMMIT']}"

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
        # Make sure N_JOBS matches allocated CPUs on SLURM
        export N_JOBS_EXT=${task.cpus}
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.versions['SPIKESORT_SC2_REPO']}" "${settings.versions['SPIKESORT_SC2_COMMIT']}"

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run ${settings.spikesorting_args} ${settings.job_args}

    echo "[${task.tag}] completed!"
    """
}

process spikesort_lupin {
    tag 'spikesort-lupin'
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
        # Make sure N_JOBS matches allocated CPUs on SLURM
        export N_JOBS_EXT=${task.cpus}
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.versions['SPIKESORT_LUPIN_REPO']}" "${settings.versions['SPIKESORT_LUPIN_COMMIT']}"

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

    ${settings.extra_installs_echo}
    ${settings.extra_installs_cmd}

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
        # Make sure N_JOBS matches allocated CPUs on SLURM
        export N_JOBS_EXT=${task.cpus}
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.versions['POSTPROCESSING_REPO']}" "${settings.versions['POSTPROCESSING_COMMIT']}"

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
        # Make sure N_JOBS matches allocated CPUs on SLURM
        export N_JOBS_EXT=${task.cpus}
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.versions['CURATION_REPO']}" "${settings.versions['CURATION_COMMIT']}"

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

    ${settings.extra_installs_echo}
    ${settings.extra_installs_cmd}

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
        # Make sure N_JOBS matches allocated CPUs on SLURM
        export N_JOBS_EXT=${task.cpus}
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.versions['VISUALIZATION_REPO']}" "${settings.versions['VISUALIZATION_COMMIT']}"

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

    ${settings.extra_installs_echo}
    ${settings.extra_installs_cmd}

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.versions['RESULTS_COLLECTOR_REPO']}" "${settings.versions['RESULTS_COLLECTOR_COMMIT']}"

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

    ${settings.extra_installs_echo}
    ${settings.extra_installs_cmd}

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
        # Make sure N_JOBS matches allocated CPUs on SLURM
        export N_JOBS_EXT=${task.cpus}
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.versions['QUALITY_CONTROL_REPO']}" "${settings.versions['QUALITY_CONTROL_COMMIT']}"

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run --pipeline-data-path ${settings.data_path}

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
    clone_repo "${settings.versions['QUALITY_CONTROL_COLLECTOR_REPO']}" "${settings.versions['QUALITY_CONTROL_COLLECTOR_COMMIT']}"

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run

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

    ${settings.extra_installs_echo}
    ${settings.extra_installs_cmd}

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    if [[ ${settings.executor} == "slurm" ]]; then
        echo "[${task.tag}] allocated task time: ${task.time}"
        # Make sure N_JOBS matches allocated CPUs on SLURM
        export N_JOBS_EXT=${task.cpus}
    fi

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.versions['NWB_ECEPHYS_REPO']}" "${settings.versions['NWB_ECEPHYS_COMMIT']}"

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

    ${settings.extra_installs_echo}
    ${settings.extra_installs_cmd}

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    echo "[${task.tag}] cloning git repo..."
    ${settings.clone_function}
    clone_repo "${settings.versions['NWB_UNITS_REPO']}" "${settings.versions['NWB_UNITS_COMMIT']}"

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
    } else if (settings.sorter == 'lupin') {
        spikesort_out = spikesort_lupin(
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

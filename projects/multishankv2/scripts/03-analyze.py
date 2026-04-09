from pathlib import Path
import argparse
import platform

import spikeinterface.full as si
import spikeinterface.extractors as se
from spikeinterface.curation import remove_excess_spikes


COMPUTE_EXTENSIONS = {
    "random_spikes": {"max_spikes_per_unit": 1000},
    "templates": {},
    "waveforms": {},
    "noise_levels": {},
    "correlograms": {},
    "spike_amplitudes": {},
    "spike_locations": {},
    "template_metrics": {"include_multi_channel_metrics": True},
    "unit_locations": {},
    "template_similarity": {"method": "l1"},
    "quality_metrics": {},
}

# Files that are characteristic of a raw Kilosort output folder
KILOSORT_RAW_FILES = {"spike_times.npy", "spike_clusters.npy", "cluster_group.tsv"}

# SpikeInterface sorter output markers (varies by SI version)
SI_SORTER_MARKERS = ["spikeinterface_log.json", "spikeinterface_info.json"]

# SpikeGLX recordings contain .meta files
SPIKEGLX_MARKER = ".ap.meta"


def is_si_sorter_folder(folder: Path) -> bool:
    return any((folder / m).is_file() for m in SI_SORTER_MARKERS)


def is_external_kilosort_folder(folder: Path) -> bool:
    return KILOSORT_RAW_FILES.issubset({f.name for f in folder.iterdir()})


def is_spikeglx_folder(folder: Path) -> bool:
    return any(f.suffix == ".meta" and ".ap" in f.name for f in folder.iterdir())


def load_recording(recording_folder: Path) -> si.BaseRecording:
    """
    Load a recording from a folder, handling both:
    - SpikeInterface binary (preprocessed/)
    - Raw SpikeGLX folder (.ap.meta / .ap.bin)
    """
    if is_spikeglx_folder(recording_folder):
        # Detect stream name from .ap.meta filename (e.g. imec0.ap.meta -> imec0.ap)
        meta_files = [f for f in recording_folder.iterdir() if ".ap.meta" in f.name]
        stream_name = None
        for meta in meta_files:
            # e.g. 999770_day1_1_g0_t0.imec1.ap.meta -> imec1.ap
            for part in meta.stem.split('.'):
                if part.startswith('imec'):
                    stream_name = f"{part}.ap"
                    break
            if stream_name:
                break
        if stream_name is None:
            raise ValueError(
                f"Could not determine stream name from .ap.meta files in: {recording_folder}"
            )
        print(f"  Detected SpikeGLX folder, loading stream '{stream_name}'...")
        return si.read_spikeglx(recording_folder, stream_name=stream_name, load_sync_channel=False)

    # Fall back to SpikeInterface binary format
    print(f"  Detected SI binary recording, loading...")
    return si.load(recording_folder)


def load_sorting_and_recording(
    sorter_folder: Path,
    recording_folder: Path | None,
) -> tuple[si.BaseSorting, si.BaseRecording]:
    """
    Load sorting and recording from a sorter folder.

    - SI sorter folder: recording is loaded from the preprocessed/ subfolder
      stored alongside the sorter. --recording_folder is ignored.
    - External Kilosort folder: --recording_folder must be provided explicitly
      since there is no embedded recording reference. Accepts both a raw
      SpikeGLX folder or a preprocessed SI binary folder.
    """
    if is_si_sorter_folder(sorter_folder):
        print(f"  Loading SI sorter object from: {sorter_folder.name}")
        sorting = si.read_sorter_folder(sorter_folder)

        preprocessed_folder = sorter_folder.parent / "preprocessed"
        if not preprocessed_folder.is_dir():
            raise FileNotFoundError(
                f"Expected preprocessed recording at: {preprocessed_folder}\n"
                "Please provide --recording_folder if the recording is elsewhere."
            )
        print(f"  Loading recording from: {preprocessed_folder}")
        recording = si.load(preprocessed_folder)
        return sorting, recording

    if is_external_kilosort_folder(sorter_folder):
        print(
            f"  [!] '{sorter_folder.name}' does not look like a SpikeInterface sorter folder.\n"
            f"      Detected raw Kilosort output (spike_times.npy / spike_clusters.npy / cluster_group.tsv).\n"
            f"      Reconstructing SpikeInterface sorting object from external Kilosort run..."
        )
        if recording_folder is None:
            raise ValueError(
                "External Kilosort output detected but no recording was provided.\n"
                "Please supply --recording_folder pointing to either a raw SpikeGLX folder\n"
                "or a preprocessed SI binary folder."
            )
        print(f"  Loading recording from: {recording_folder}")
        recording = load_recording(recording_folder)
        sorting = se.read_kilosort(sorter_folder)
        # Override sampling frequency from the recording since
        # read_kilosort() may not have access to it from the folder alone
        sorting._sampling_frequency = recording.get_sampling_frequency()
        print(f"  Sorting object reconstructed: {sorting.get_num_units()} units found.")
        return sorting, recording

    raise ValueError(
        f"Cannot identify the contents of '{sorter_folder}' as either a SpikeInterface sorter "
        f"output or a raw Kilosort output.\n"
        f"Expected either {SI_SORTER_MARKERS} (SI) or {KILOSORT_RAW_FILES} (raw Kilosort)."
    )


def build_analyzer(sorting, recording, folder):
    analyzer = si.create_sorting_analyzer(
        sorting=sorting,
        recording=recording,
        folder=folder,
        format="binary_folder",
        overwrite=True,
    )
    analyzer.compute(COMPUTE_EXTENSIONS)
    return analyzer


def main():
    parser = argparse.ArgumentParser(
        description='Step 3: Build sorting analyzers',
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument('output_folder', type=str,
                        help='Path to output folder (analyzers will be saved here)')
    parser.add_argument(
        '--sorter_folder', '-s',
        type=str,
        default=None,
        metavar='SORTER_FOLDER',
        help=(
            'Path to a specific sorter folder to analyze.\n'
            'Can be an absolute path or a name relative to output_folder.\n'
            'If not provided, all sorter_* subfolders are processed.\n'
            'Examples:\n'
            '  --sorter_folder sorter_kilosort4\n'
            '  --sorter_folder /absolute/path/to/sorter_kilosort4'
        ),
    )
    parser.add_argument(
        '--recording_folder', '-r',
        type=str,
        default=None,
        metavar='RECORDING_FOLDER',
        help=(
            'Path to the recording folder.\n'
            'Only required when the sorter folder is a raw external Kilosort output.\n'
            'Accepts either a raw SpikeGLX folder or a preprocessed SI binary folder.\n'
            'SI sorter folders already contain a reference to the recording.\n'
            'Example:\n'
            '  --recording_folder /path/to/spikeglx_or_preprocessed'
        ),
    )
    args = parser.parse_args()

    mp_context = 'fork' if platform.system() != 'Windows' else 'spawn'
    global_job_kwargs = dict(n_jobs=20, mp_context=mp_context, progress_bar=True)
    si.set_global_job_kwargs(**global_job_kwargs)

    output_folder = Path(args.output_folder)
    output_folder.mkdir(parents=True, exist_ok=True)

    recording_folder = Path(args.recording_folder) if args.recording_folder else None

    # Resolve sorter folders: specific one or auto-discover all
    if args.sorter_folder is not None:
        sorter_path = Path(args.sorter_folder)
        if not sorter_path.is_absolute():
            sorter_path = output_folder / sorter_path
        if not sorter_path.is_dir():
            raise FileNotFoundError(f"Sorter folder not found: {sorter_path}")
        sorter_folders = [sorter_path]
    else:
        sorter_folders = sorted(output_folder.glob("sorter_*"))
        if not sorter_folders:
            raise FileNotFoundError(
                f"No 'sorter_*' folders found in: {output_folder}\n"
                "Please run 02-sort.py first or specify --sorter_folder."
            )

    for sorter_folder in sorter_folders:
        analyzer_name = sorter_folder.name.replace("sorter_", "analyzer_", 1)
        if not analyzer_name.startswith("analyzer_"):
            analyzer_name = f"analyzer_{analyzer_name}"
        analyzer_folder = output_folder / analyzer_name

        print(f"\nProcessing: {sorter_folder.name}")
        sorting, recording = load_sorting_and_recording(sorter_folder, recording_folder)

        # Remove spikes that exceed the recording duration (e.g. KS4 edge artifacts)
        sorting = remove_excess_spikes(sorting, recording)

        print(f"  Building analyzer -> {analyzer_name}")
        build_analyzer(sorting, recording, analyzer_folder)

    print(f"\nAnalysis complete! Results saved in: {output_folder}")


if __name__ == "__main__":
    main()

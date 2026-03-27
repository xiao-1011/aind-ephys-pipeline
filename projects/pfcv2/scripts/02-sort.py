from pathlib import Path
import argparse

import spikeinterface.full as si


# Sorter-specific kwargs
SORTER_KWARGS = {
    'kilosort4':      dict(do_correction=False),
    'kilosort3':      dict(do_correction=False),
    'kilosort2_5':    dict(do_correction=False),
    'kilosort2':      dict(do_correction=False),
    'mountainsort5':  {},
    'tridesclous2':   {},
    'spykingcircus2': {},
    'ironclust':      {},
    'yass':           {},
}

AVAILABLE_SORTERS = list(SORTER_KWARGS.keys())


def run_sorter(sorter_name, recording, working_folder):
    sorter_key = sorter_name.lower().replace('-', '_')
    kwargs = dict(SORTER_KWARGS.get(sorter_key, {}))  # copy to avoid mutating the global
    sorter_folder = working_folder / f"sorter_{sorter_key}"

    # For any Kilosort variant, instruct it to write a binary file so the
    # raw output can be read back as an external Kilosort run if needed.
    if sorter_key.startswith('kilosort'):
        kwargs['use_binary_file'] = True

    print(f"\nSorting with {sorter_name}...")
    si.run_sorter(
        sorter_key,
        recording,
        folder=sorter_folder,
        verbose=True,
        remove_existing_folder=True,
        **kwargs,
    )
    print(f"  -> Saved to: {sorter_folder}")


def main():
    parser = argparse.ArgumentParser(
        description='Step 2: Spike sort preprocessed recording',
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument('output_folder', type=str,
                        help='Path to output folder (same as used in preprocessing)')
    parser.add_argument(
        '--sorters', '-s',
        nargs='+',
        default=['kilosort4'],
        metavar='SORTER',
        help=(
            'One or more sorters to run (space-separated).\n'
            f'Available: {", ".join(AVAILABLE_SORTERS)}\n'
            'Default: kilosort4\n'
            'Examples:\n'
            '  --sorters kilosort4\n'
            '  --sorters kilosort4 ironclust yass'
        ),
    )
    args = parser.parse_args()

    global_job_kwargs = dict(n_jobs=20, mp_context='fork', progress_bar=True)
    si.set_global_job_kwargs(**global_job_kwargs)

    working_folder = Path(args.output_folder)
    preprocessed_folder = working_folder / "preprocessed"

    if not preprocessed_folder.is_dir():
        raise FileNotFoundError(
            f"Preprocessed recording not found at: {preprocessed_folder}\n"
            "Please run 01-preprocess.py first."
        )

    print("Loading preprocessed recording...")
    recording_preprocessed = si.load(preprocessed_folder)

    print(f"Sorters to run: {args.sorters}")
    for sorter in args.sorters:
        run_sorter(sorter, recording_preprocessed, working_folder)

    print(f"\nSpike sorting complete. Results saved in: {working_folder}")


if __name__ == "__main__":
    main()

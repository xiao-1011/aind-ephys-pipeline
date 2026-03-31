"""Step 6: Compare sortings across all sorters to identify consensus units.

A unit is 'in consensus' if it is matched by at least --min-agreement sorters
in total (i.e. matched in at least --min-agreement - 1 other sorters).

All sorter_* subfolders in the output folder are discovered automatically.

Saves consensus_labels.json with per-unit consensus flags for all sorters.
This file is read by 04-curate.py and propagated into the NWB units table.
"""
from pathlib import Path
from itertools import combinations
import argparse
import json

import spikeinterface.full as si


def main():
    parser = argparse.ArgumentParser(
        description='Step 6: Multi-sorter consensus comparison',
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument('output_folder', type=str,
                        help='Path to output folder (same as previous steps)')
    parser.add_argument(
        '--agreement-threshold', type=float, default=0.5,
        metavar='FLOAT',
        help='Min spike-overlap fraction to count as a matched unit (default: 0.5)',
    )
    parser.add_argument(
        '--min-agreement', type=int, default=2,
        metavar='INT',
        help=(
            'Minimum number of sorters that must detect a unit to be in consensus.\n'
            'E.g. 2 = found by any 2 sorters, 3 = found by any 3 sorters (default: 2)'
        ),
    )
    args = parser.parse_args()

    output_folder = Path(args.output_folder)

    sorter_folders = sorted(f for f in output_folder.glob('sorter_*') if f.is_dir())
    if len(sorter_folders) < 2:
        raise ValueError(
            f"Need at least 2 sorter_* folders for comparison, "
            f"found: {[f.name for f in sorter_folders]}"
        )

    print("Loading sortings...")
    sortings = []
    names = []
    for folder in sorter_folders:
        name = folder.name.replace('sorter_', '', 1)
        sorting = si.load_extractor(folder)
        sortings.append(sorting)
        names.append(name)
        print(f"  {name}: {len(sorting.get_unit_ids())} units")

    # Initialise per-sorter, per-unit match counters (how many other sorters matched)
    match_counts = {
        name: {str(uid): 0 for uid in sorting.get_unit_ids()}
        for name, sorting in zip(names, sortings)
    }

    # Pairwise comparisons — O(N^2/2) but N is small (2-6 sorters)
    for (i, name_i), (j, name_j) in combinations(enumerate(names), 2):
        print(f"\nComparing {name_i} vs {name_j}...")
        cmp = si.compare_two_sorters(
            sortings[i], sortings[j],
            sorting1_name=name_i,
            sorting2_name=name_j,
            match_score=args.agreement_threshold,
        )
        match_12 = cmp.hungarian_match_12
        match_21 = cmp.hungarian_match_21

        for uid in sortings[i].get_unit_ids():
            if int(match_12[uid]) != -1:
                match_counts[name_i][str(uid)] += 1

        for uid in sortings[j].get_unit_ids():
            if int(match_21[uid]) != -1:
                match_counts[name_j][str(uid)] += 1

    # A unit is in consensus if matched in >= (min_agreement - 1) other sorters,
    # meaning it was detected by min_agreement sorters in total (including itself).
    other_sorter_threshold = args.min_agreement - 1

    print(f"\nConsensus threshold: detected by ≥{args.min_agreement} of {len(names)} sorters")

    output = {
        'agreement_threshold': args.agreement_threshold,
        'min_agreement': args.min_agreement,
        'sorters': names,
    }

    for name, sorting in zip(names, sortings):
        counts = match_counts[name]
        consensus = {
            uid_str: (count >= other_sorter_threshold)
            for uid_str, count in counts.items()
        }
        n_consensus = sum(consensus.values())
        n_total = len(sorting.get_unit_ids())
        print(f"  {name}: {n_consensus}/{n_total} in consensus")
        output[name] = {
            'n_total':     n_total,
            'n_consensus': n_consensus,
            'consensus':   consensus,
        }

    output_file = output_folder / 'consensus_labels.json'
    with open(output_file, 'w') as f:
        json.dump(output, f, indent=2)
    print(f"\nConsensus labels saved to: {output_file}")


if __name__ == "__main__":
    main()

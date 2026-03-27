"""Step 6: Compare KS4 and SpykingCircus2 sortings to identify consensus units.

A unit is 'in consensus' if it is matched to a unit in the other sorter with
sufficient spike-train overlap (default threshold: 50%).

Saves consensus_labels.json with per-unit consensus flags for both sorters.
This file is read by 04-curate.py and propagated into the NWB units table.
"""
from pathlib import Path
import argparse
import json

import spikeinterface.full as si


def main():
    parser = argparse.ArgumentParser(
        description='Step 6: Compare KS4 and SpykingCircus2 sortings',
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument('output_folder', type=str,
                        help='Path to output folder (same as previous steps)')
    parser.add_argument(
        '--agreement-threshold', type=float, default=0.5,
        metavar='FLOAT',
        help='Min spike-overlap fraction to count as a matched unit (default: 0.5)',
    )
    args = parser.parse_args()

    output_folder = Path(args.output_folder)
    sorter1_folder = output_folder / 'sorter_kilosort4'
    sorter2_folder = output_folder / 'sorter_spykingcircus2'

    if not sorter1_folder.is_dir():
        raise FileNotFoundError(f"Sorter folder not found: {sorter1_folder}")
    if not sorter2_folder.is_dir():
        raise FileNotFoundError(f"Sorter folder not found: {sorter2_folder}")

    print("Loading sortings...")
    sorting1 = si.load_extractor(sorter1_folder)
    sorting2 = si.load_extractor(sorter2_folder)
    print(f"  kilosort4:      {len(sorting1.get_unit_ids())} units")
    print(f"  spykingcircus2: {len(sorting2.get_unit_ids())} units")

    print(f"Comparing sortings (agreement threshold: {args.agreement_threshold})...")
    comparison = si.compare_two_sorters(
        sorting1, sorting2,
        sorting1_name='kilosort4',
        sorting2_name='spykingcircus2',
        match_score=args.agreement_threshold,
    )

    # hungarian_match_12: Series, index = sorting1 unit IDs, values = matched sorting2 ID (-1 = none)
    match_12 = comparison.hungarian_match_12
    match_21 = comparison.hungarian_match_21

    ks4_consensus = {
        str(uid): (int(match_12[uid]) != -1) for uid in sorting1.get_unit_ids()
    }
    sc2_consensus = {
        str(uid): (int(match_21[uid]) != -1) for uid in sorting2.get_unit_ids()
    }

    n_ks4 = sum(ks4_consensus.values())
    n_sc2 = sum(sc2_consensus.values())
    print(f"  kilosort4 in consensus:      {n_ks4}/{len(ks4_consensus)}")
    print(f"  spykingcircus2 in consensus: {n_sc2}/{len(sc2_consensus)}")

    output = {
        'agreement_threshold': args.agreement_threshold,
        'kilosort4': {
            'n_total':    len(sorting1.get_unit_ids()),
            'n_consensus': n_ks4,
            'consensus':   ks4_consensus,
        },
        'spykingcircus2': {
            'n_total':    len(sorting2.get_unit_ids()),
            'n_consensus': n_sc2,
            'consensus':   sc2_consensus,
        },
    }

    output_file = output_folder / 'consensus_labels.json'
    with open(output_file, 'w') as f:
        json.dump(output, f, indent=2)
    print(f"Consensus labels saved to: {output_file}")


if __name__ == "__main__":
    main()

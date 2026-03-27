"""Step 4: Auto-curate sorted units based on quality metric thresholds.

Reads quality metrics from the SortingAnalyzer extension CSVs and writes
a curation JSON file with per-unit labels and the full metrics table.
This file is the input for step 5 (NWB export) and can be inspected manually
to verify that automatic thresholds match manual curation expectations.
"""
from pathlib import Path
import argparse
import json

import pandas as pd


DEFAULT_THRESHOLDS = {
    "isi_violations_ratio": {"max": 0.5},
    "presence_ratio":       {"min": 0.8},
    "amplitude_cutoff":     {"max": 0.1},
}


def _load_consensus(output_folder: Path, sorter_name: str) -> dict | None:
    """Read per-unit consensus flags for this sorter from consensus_labels.json, if present."""
    consensus_file = output_folder / "consensus_labels.json"
    if not consensus_file.is_file():
        return None
    with open(consensus_file) as f:
        data = json.load(f)
    sorter_data = data.get(sorter_name)
    if sorter_data is None:
        return None
    return sorter_data.get("consensus", {})


def curate_analyzer(analyzer_folder: Path, thresholds: dict) -> Path:
    """Apply thresholds to quality metrics and write curation_{sorter}.json."""
    sorter_name = analyzer_folder.name.replace("analyzer_", "", 1)

    qm_csv = analyzer_folder / "extensions" / "quality_metrics" / "quality_metrics.csv"
    if not qm_csv.is_file():
        raise FileNotFoundError(
            f"Quality metrics not found at: {qm_csv}\n"
            "Please run 03-analyze.py first."
        )

    qm = pd.read_csv(qm_csv, index_col=0)

    mask = pd.Series(True, index=qm.index)
    for metric, bounds in thresholds.items():
        if metric not in qm.columns:
            print(f"  Warning: metric '{metric}' not in quality_metrics.csv — skipping.")
            continue
        if "max" in bounds:
            mask &= qm[metric] <= bounds["max"]
        if "min" in bounds:
            mask &= qm[metric] >= bounds["min"]

    good_ids = qm.index[mask].tolist()
    bad_ids  = qm.index[~mask].tolist()

    labels = {str(uid): "good" for uid in good_ids}
    labels.update({str(uid): "bad" for uid in bad_ids})

    # Serialize full QM table so NWB export doesn't need to reload the analyzer
    qm_records = qm.to_dict(orient="index")
    qm_serialisable = {
        str(uid): {k: (None if pd.isna(v) else v) for k, v in row.items()}
        for uid, row in qm_records.items()
    }

    # Attach per-unit consensus flag if available
    consensus = _load_consensus(analyzer_folder.parent, sorter_name)
    if consensus is not None:
        n_consensus = sum(bool(v) for v in consensus.values())
        print(f"  consensus units: {n_consensus}/{len(consensus)}")
    else:
        print("  consensus_labels.json not found — skipping consensus field")

    output = {
        "sorter": sorter_name,
        "thresholds": thresholds,
        "n_good": len(good_ids),
        "n_bad":  len(bad_ids),
        "labels": labels,
        "quality_metrics": qm_serialisable,
        "consensus": consensus,  # None if single-sorter run
    }

    labels_file = analyzer_folder.parent / f"curation_{sorter_name}.json"
    with open(labels_file, "w") as f:
        json.dump(output, f, indent=2)

    print(f"  {sorter_name}: {len(good_ids)} good, {len(bad_ids)} bad → {labels_file.name}")
    return labels_file


def main():
    parser = argparse.ArgumentParser(
        description="Step 4: Auto-curate sorted units",
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument("output_folder", type=str,
                        help="Path to output folder (same as previous steps)")
    parser.add_argument(
        "--isi-max", type=float, default=DEFAULT_THRESHOLDS["isi_violations_ratio"]["max"],
        metavar="FLOAT",
        help=f"Max ISI violation ratio (default: {DEFAULT_THRESHOLDS['isi_violations_ratio']['max']})",
    )
    parser.add_argument(
        "--presence-min", type=float, default=DEFAULT_THRESHOLDS["presence_ratio"]["min"],
        metavar="FLOAT",
        help=f"Min presence ratio (default: {DEFAULT_THRESHOLDS['presence_ratio']['min']})",
    )
    parser.add_argument(
        "--amplitude-cutoff-max", type=float, default=DEFAULT_THRESHOLDS["amplitude_cutoff"]["max"],
        metavar="FLOAT",
        help=f"Max amplitude cutoff (default: {DEFAULT_THRESHOLDS['amplitude_cutoff']['max']})",
    )
    args = parser.parse_args()

    thresholds = {
        "isi_violations_ratio": {"max": args.isi_max},
        "presence_ratio":       {"min": args.presence_min},
        "amplitude_cutoff":     {"max": args.amplitude_cutoff_max},
    }

    output_folder = Path(args.output_folder)
    analyzer_folders = sorted(output_folder.glob("analyzer_*"))
    if not analyzer_folders:
        raise FileNotFoundError(
            f"No 'analyzer_*' folders found in: {output_folder}\n"
            "Please run 03-analyze.py first."
        )

    print(f"Curation thresholds: {json.dumps(thresholds, indent=2)}")
    for analyzer_folder in analyzer_folders:
        print(f"\nCurating: {analyzer_folder.name}")
        curate_analyzer(analyzer_folder, thresholds)

    print("\nCuration complete.")


if __name__ == "__main__":
    main()

"""Step 9: Offline manual curation with SpikeInterface GUI.

NOT part of the Nextflow pipeline — runs locally on macOS/Linux desktop after
downloading results from Dardel.

Loads the SortingAnalyzer and restores all labels computed by
07-advanced-curate.py (UnitRefine, bombcell, passing_qc) as sorting properties,
then launches the SpikeInterface GUI for manual curation.

Usage:
    python 09-offline-curate.py /path/to/analyzer_kilosort4

The analyzer folder should contain (produced by 07-advanced-curate.py on Dardel):
  - curation.json           (CurationModel v2 — merges, removed, labels)
  - unitrefine_labels.json  (noise/neural + SUA/MUA predictions)
  - bombcell_labels.json    (good/MUA/noise rule-based labels)
  - passing_qc.json         (QM-based pass/fail)
"""
from pathlib import Path
import argparse
import json

import numpy as np
import spikeinterface.full as si


def main():
    parser = argparse.ArgumentParser(
        description="Step 8: Offline manual curation (SpikeInterface GUI)",
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument(
        "analyzer_folder", type=str,
        help="Path to the analyzer folder (e.g. analyzer_kilosort4)",
    )
    parser.add_argument(
        "--settings", type=str, default=None,
        help="Path to SI GUI quality_settings.json (optional)",
    )
    parser.add_argument(
        "--layout", type=str, default=None,
        help="Path to SI GUI layout JSON (optional)",
    )
    args = parser.parse_args()

    analyzer_folder = Path(args.analyzer_folder)
    curation_file = analyzer_folder / "curation.json"
    unitrefine_file = analyzer_folder / "unitrefine_labels.json"
    bombcell_file = analyzer_folder / "bombcell_labels.json"
    passing_qc_file = analyzer_folder / "passing_qc.json"

    # ── Load analyzer ────────────────────────────────────────────────────
    print(f"Loading analyzer: {analyzer_folder}")
    analyzer = si.load(analyzer_folder, load_extensions=True)
    print(f"  {len(analyzer.unit_ids)} units")

    # ── Load or create curation dict ─────────────────────────────────────
    if curation_file.exists():
        print(f"Loading curation from: {curation_file.name}")
        curation_dict = json.loads(curation_file.read_text())
    else:
        print("No curation.json found — starting fresh")
        curation_dict = None

    # ── Restore UnitRefine labels ────────────────────────────────────────
    if unitrefine_file.exists():
        unitrefine_dict = json.loads(unitrefine_file.read_text())
        pred_map = unitrefine_dict["unitrefine_prediction"]
        prob_map = unitrefine_dict["unitrefine_probability"]

        predictions = np.array(
            [pred_map.get(str(uid), "unknown") for uid in analyzer.unit_ids],
            dtype="U10",
        )
        probabilities = np.array(
            [prob_map.get(str(uid), 0.0) for uid in analyzer.unit_ids],
            dtype=float,
        )
        analyzer.set_sorting_property("unitrefine_prediction", predictions)
        analyzer.set_sorting_property("unitrefine_probability", probabilities)
        print(f"Restored UnitRefine labels from {unitrefine_file.name}")
    else:
        print(f"  {unitrefine_file.name} not found — skipping UnitRefine labels")

    # ── Restore bombcell labels ──────────────────────────────────────────
    if bombcell_file.exists():
        bombcell_dict = json.loads(bombcell_file.read_text())
        label_map = bombcell_dict["bombcell_label"]
        bc_labels = np.array(
            [label_map.get(str(uid), "unknown") for uid in analyzer.unit_ids],
            dtype="U10",
        )
        analyzer.set_sorting_property("bombcell_label", bc_labels)
        print(f"Restored bombcell labels from {bombcell_file.name}")
    else:
        print(f"  {bombcell_file.name} not found — skipping bombcell labels")

    # ── Restore passing_qc ───────────────────────────────────────────────
    if passing_qc_file.exists():
        pq_dict = json.loads(passing_qc_file.read_text())
        passing_qc = np.array(
            [pq_dict.get(str(uid), False) for uid in analyzer.unit_ids],
            dtype=bool,
        )
        analyzer.set_sorting_property("passing_qc", passing_qc)
        print(f"Restored passing_qc from {passing_qc_file.name}")
    else:
        print(f"  {passing_qc_file.name} not found — skipping passing_qc")

    # ── Build extra properties dict for GUI columns ──────────────────────
    extra_props = {}
    for prop_name in ["passing_qc", "unitrefine_prediction", "unitrefine_probability",
                      "bombcell_label", "KSLabel"]:
        try:
            values = analyzer.sorting.get_property(prop_name)
            if values is not None:
                if prop_name in ("unitrefine_prediction", "bombcell_label", "KSLabel"):
                    values = np.array(values, dtype="U10")
                extra_props[prop_name] = values
        except Exception:
            pass

    # ── Load optional GUI settings/layout ────────────────────────────────
    settings_dict = None
    layout_dict = None
    if args.settings and Path(args.settings).exists():
        with open(args.settings) as f:
            settings_dict = json.load(f)
    if args.layout and Path(args.layout).exists():
        with open(args.layout) as f:
            layout_dict = json.load(f)

    # ── Launch GUI ───────────────────────────────────────────────────────
    print(f"\nLaunching SpikeInterface GUI...")
    from spikeinterface_gui import run_mainwindow

    gui_kwargs = dict(
        analyzer=analyzer,
        mode="desktop",
        curation=True,
    )
    if extra_props:
        gui_kwargs["extra_unit_properties"] = extra_props
    if curation_dict is not None:
        gui_kwargs["curation_dict"] = curation_dict
    if layout_dict is not None:
        gui_kwargs["layout"] = layout_dict
    if settings_dict is not None:
        gui_kwargs["user_settings"] = settings_dict

    run_mainwindow(**gui_kwargs)


if __name__ == "__main__":
    main()

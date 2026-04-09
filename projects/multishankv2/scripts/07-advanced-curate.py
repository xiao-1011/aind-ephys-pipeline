"""Step 7: Advanced per-sorter curation on the server (headless).

Runs redundant unit removal, UnitRefine noise/neural classification,
auto-merge of split units, bombcell labeling, and UnitRefine SUA/MUA
classification.  Produces a *clean sorting* (noise removed + merges applied)
for a second consensus comparison (COMPARE_CLEAN), plus label JSONs consumed
by 04-curate.py and the offline GUI script (09-offline-curate.py).

Adapted from pfc-scripts/Advanced_curation3.py — everything except the GUI.

Usage (standalone test):
    python 07-advanced-curate.py /path/to/probe_output --analyzer_folder analyzer_kilosort4

Usage (Nextflow):
    python 07-advanced-curate.py . --analyzer_folder ${analyzer_dir}
"""
from pathlib import Path
import argparse
import json
import platform

import os

import numpy as np
import pandas as pd

import spikeinterface.full as si
import spikeinterface.curation as sc
from spikeinterface.curation import validate_curation_dict


# ── Helpers ──────────────────────────────────────────────────────────────────

def _int(uid):
    """Convert numpy integers to plain Python int for JSON serialisation."""
    return int(uid) if isinstance(uid, np.integer) else uid


def _resolve_hf_model_path(repo_id):
    """Resolve a HuggingFace repo_id to its local cache snapshot path.

    Works fully offline — just reads the filesystem, no HF API calls.
    Models must have been pre-cached via ``snapshot_download(repo_id)``
    before calling this function (done in slurm_submit.sh).
    """
    hf_home = os.environ.get("HF_HOME", os.path.join(os.path.expanduser("~"), ".cache", "huggingface"))
    model_dir_name = "models--" + repo_id.replace("/", "--")
    snapshots_dir = os.path.join(hf_home, "hub", model_dir_name, "snapshots")
    if not os.path.isdir(snapshots_dir):
        raise FileNotFoundError(
            f"Model not found in HF cache: {snapshots_dir}\n"
            f"Run snapshot_download('{repo_id}') first (done in slurm_submit.sh)."
        )
    hashes = sorted(os.listdir(snapshots_dir))
    if not hashes:
        raise FileNotFoundError(f"No snapshots found in: {snapshots_dir}")
    return os.path.join(snapshots_dir, hashes[-1])


def _apply_merges_and_remove(sorting, merge_groups, remove_ids):
    """Apply merge groups and remove noise units, returning a clean sorting.

    Tries the SI 0.104+ ``apply_curation`` API first; falls back to manual
    construction if it is unavailable.
    """
    # Build a CurationModel-style dict for apply_curation
    curation_dict = dict(
        format_version="2",
        unit_ids=[_int(u) for u in sorting.unit_ids],
        label_definitions={},
        merges=[
            dict(unit_ids=[_int(u) for u in group])
            for group in merge_groups
        ],
        removed=[_int(u) for u in remove_ids],
        manual_labels=[],
    )

    # Try the unified API first (SI >= 0.104)
    try:
        from spikeinterface.curation import apply_curation
        return apply_curation(sorting, curation_dict)
    except ImportError:
        pass

    # Fallback: manual merge + removal
    # 1. Apply merges
    if merge_groups:
        try:
            from spikeinterface.curation import MergeUnitsSorting
            sorting = MergeUnitsSorting(sorting, merge_groups)
        except ImportError:
            # Last resort: just skip merges if no API available
            print("  Warning: could not apply merges (MergeUnitsSorting not found)")

    # 2. Remove noise units (only those still present after merge)
    remaining = set(sorting.unit_ids)
    to_remove = set(_int(u) for u in remove_ids)
    keep_ids = [uid for uid in sorting.unit_ids if uid not in to_remove]
    if len(keep_ids) < len(sorting.unit_ids):
        sorting = sorting.select_units(keep_ids)

    return sorting


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Step 7: Advanced per-sorter curation (headless)",
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument(
        "output_folder", type=str,
        help="Path to output folder (clean sorting + JSONs saved here)",
    )
    parser.add_argument(
        "--analyzer_folder", "-a", type=str, required=True,
        metavar="ANALYZER_FOLDER",
        help="Path to the analyzer folder to curate (e.g. analyzer_kilosort4)",
    )
    args = parser.parse_args()

    mp_context = "fork" if platform.system() != "Windows" else "spawn"
    si.set_global_job_kwargs(n_jobs=-1, mp_context=mp_context, progress_bar=True)

    output_folder = Path(args.output_folder)
    output_folder.mkdir(parents=True, exist_ok=True)

    analyzer_path = Path(args.analyzer_folder)
    if not analyzer_path.is_absolute():
        analyzer_path = output_folder / analyzer_path
    sorter_name = analyzer_path.name.replace("analyzer_", "", 1)

    # ── Load analyzer ────────────────────────────────────────────────────
    print(f"\nLoading analyzer: {analyzer_path.name}")
    analyzer = si.load(analyzer_path, load_extensions=True)
    n_original = len(analyzer.unit_ids)
    print(f"  {n_original} units loaded")

    # Quality metrics must already exist (computed by 03-analyze.py)
    if analyzer.get_extension("quality_metrics") is None:
        raise RuntimeError(
            f"quality_metrics extension missing from {analyzer_path.name}.\n"
            "Please run 03-analyze.py first."
        )
    qm = analyzer.get_extension("quality_metrics").get_data()

    # ── Phase 1: Clean the sorting (affects COMPARE_CLEAN) ──────────────

    # 1a. Remove redundant units
    print("\n--- Remove redundant units ---")
    sorting_dedup = sc.remove_redundant_units(analyzer)
    n_redundant = n_original - len(sorting_dedup.unit_ids)
    if n_redundant > 0:
        print(f"  Removed {n_redundant} redundant units")
        analyzer = analyzer.select_units(sorting_dedup.unit_ids)
    else:
        print("  No redundant units found")
    n_after_dedup = len(analyzer.unit_ids)

    # 1b. UnitRefine noise/neural classifier
    print("\n--- UnitRefine noise/neural classifier ---")
    _noise_repo = "SpikeInterface/UnitRefine_noise_neural_classifier_lightweight"
    noise_neuron_labels = sc.model_based_label_units(
        sorting_analyzer=analyzer,
        model_folder=_resolve_hf_model_path(_noise_repo),
        trust_model=True,
    )
    noise_units = noise_neuron_labels[noise_neuron_labels["prediction"] == "noise"]
    neural_units = noise_neuron_labels[noise_neuron_labels["prediction"] != "noise"]
    print(f"  Noise: {len(noise_units)} / {n_after_dedup}")
    print(f"  Neural: {len(neural_units)} / {n_after_dedup}")

    analyzer_neural = analyzer.select_units(list(neural_units.index))

    # 1c. Auto-merge split units (on neural units only)
    print("\n--- Auto-merge (similarity_correlograms) ---")
    merge_groups = sc.compute_merge_unit_groups(
        analyzer_neural,
        preset="similarity_correlograms",
        steps_params={"template_similarity": {"template_diff_thresh": 0.5}},
    )
    n_merges = len(merge_groups)
    n_units_merged = sum(len(g) for g in merge_groups)
    print(f"  {n_merges} merge groups ({n_units_merged} units → {n_merges} merged)")

    # 1d. Build and save clean sorting (noise removed + merges applied)
    print("\n--- Saving clean sorting ---")
    clean_sorting = _apply_merges_and_remove(
        analyzer.sorting, merge_groups, noise_units.index
    )
    n_clean = len(clean_sorting.unit_ids)
    print(f"  {n_original} → {n_clean} clean units "
          f"(-{n_redundant} redundant, -{len(noise_units)} noise, "
          f"-{n_units_merged - n_merges} merged)")

    clean_folder = output_folder / f"sorting_clean_{sorter_name}"
    clean_sorting.save(folder=clean_folder, overwrite=True)
    print(f"  Saved to: {clean_folder.name}")

    # ── Phase 2: Label everything (for GUI / downstream CURATE) ─────────

    # 2a. UnitRefine SUA/MUA classifier (on neural units only)
    print("\n--- UnitRefine SUA/MUA classifier ---")
    _sua_repo = "SpikeInterface/UnitRefine_sua_mua_classifier_lightweight"
    sua_mua_labels = sc.model_based_label_units(
        sorting_analyzer=analyzer_neural,
        model_folder=_resolve_hf_model_path(_sua_repo),
        trust_model=True,
    )
    # Merge with noise labels for a complete per-unit table
    unit_refine_labels = pd.concat([sua_mua_labels, noise_units]).sort_index()
    sua_units = sua_mua_labels[sua_mua_labels["prediction"] == "sua"]
    mua_units = sua_mua_labels[sua_mua_labels["prediction"] == "mua"]
    print(f"  SUA: {len(sua_units)} / MUA: {len(mua_units)} / Noise: {len(noise_units)}")

    # 2b. Bombcell labels (on full analyzer, before noise removal)
    print("\n--- Bombcell classification ---")
    available_metrics = set(qm.columns)
    bc_thresholds = sc.bombcell_get_default_thresholds()
    for category in bc_thresholds.values():
        keys_to_remove = [m for m in list(category.keys()) if m not in available_metrics]
        for m in keys_to_remove:
            category.pop(m)
    bc_unit_labels = sc.bombcell_label_units(
        sorting_analyzer=analyzer, thresholds=bc_thresholds
    )
    bc_good = int(np.sum(bc_unit_labels == "good"))
    bc_mua = int(np.sum(bc_unit_labels == "mua"))
    bc_noise = int(np.sum(bc_unit_labels == "noise"))
    print(f"  good: {bc_good} / MUA: {bc_mua} / noise: {bc_noise}")

    # 2c. QM-based passing_qc (stricter thresholds from Advanced_curation3)
    curation_query = (
        "amplitude_cutoff < 0.1 and presence_ratio > 0.95 and isi_violations_ratio < 1"
    )
    qm_filtered = qm.query(curation_query)
    units_passing = list(qm_filtered.index)
    # Filter to IDs still present after redundancy removal + noise removal + merge
    valid_ids = set(analyzer.sorting.unit_ids)
    units_passing = [u for u in units_passing if u in valid_ids]
    passing_qc = np.zeros(len(analyzer.unit_ids), dtype=bool)
    passing_qc[analyzer.sorting.ids_to_indices(units_passing)] = True
    print(f"\n--- QM passing_qc ---")
    print(f"  {len(units_passing)} / {len(analyzer.unit_ids)} pass")

    # ── Save outputs ────────────────────────────────────────────────────

    # A. Advanced curation JSON (consumed by 04-curate.py)
    adv_curation = {
        "sorter": sorter_name,
        "n_original_units": n_original,
        "n_redundant_removed": n_redundant,
        "n_noise_removed": len(noise_units),
        "n_merge_groups": n_merges,
        "n_clean_units": n_clean,
        "merge_groups": [[_int(u) for u in g] for g in merge_groups],
        "noise_unit_ids": [_int(u) for u in noise_units.index],
        "redundant_unit_ids": [
            _int(u) for u in set(range(n_original)) - set(sorting_dedup.unit_ids)
        ] if n_redundant > 0 else [],
        "unitrefine_labels": {
            str(_int(uid)): {
                "prediction": str(row["prediction"]),
                "probability": float(row["probability"]),
            }
            for uid, row in unit_refine_labels.iterrows()
        },
        "bombcell_labels": {
            str(_int(uid)): (
                str(label[0]) if isinstance(label, (list, np.ndarray)) else str(label)
            )
            for uid, label in zip(
                analyzer.unit_ids,
                bc_unit_labels.reindex(analyzer.unit_ids).values,
            )
        },
        "passing_qc": {
            str(_int(uid)): bool(pq)
            for uid, pq in zip(analyzer.unit_ids, passing_qc)
        },
    }
    adv_file = output_folder / f"advanced_curation_{sorter_name}.json"
    with open(adv_file, "w") as f:
        json.dump(adv_curation, f, indent=2)
    print(f"\nAdvanced curation saved to: {adv_file.name}")

    # B. CurationModel v2 dict (for offline GUI / spikeinterface_gui)
    label_definitions = {
        "quality": dict(
            name="quality", label_options=["good", "MUA", "noise"], exclusive=True
        ),
    }
    curation_dict = dict(
        format_version="2",
        unit_ids=[_int(u) for u in analyzer.unit_ids],
        label_definitions=label_definitions,
        merges=[
            dict(unit_ids=[_int(u) for u in g]) for g in merge_groups
        ],
        removed=[_int(u) for u in noise_units.index],
        manual_labels=[],
    )
    validate_curation_dict(curation_dict)
    from spikeinterface.curation.curation_model import CurationModel
    curation = CurationModel(**curation_dict)
    curation_file = analyzer_path / "curation.json"
    curation_file.write_text(curation.model_dump_json(indent=4))
    print(f"CurationModel saved to: {curation_file}")

    # C. Auxiliary JSONs for offline GUI resume (inside analyzer folder)
    unitrefine_dict = {
        "unitrefine_prediction": {
            _int(uid): str(pred)
            for uid, pred in zip(
                analyzer.unit_ids,
                unit_refine_labels["prediction"].reindex(analyzer.unit_ids).values,
            )
        },
        "unitrefine_probability": {
            _int(uid): float(prob)
            for uid, prob in zip(
                analyzer.unit_ids,
                unit_refine_labels["probability"].reindex(analyzer.unit_ids).values,
            )
        },
    }
    unitrefine_file = analyzer_path / "unitrefine_labels.json"
    unitrefine_file.write_text(json.dumps(unitrefine_dict, indent=4))
    print(f"UnitRefine labels saved to: {unitrefine_file.name}")

    bombcell_dict = {
        "bombcell_label": {
            _int(uid): (
                str(label[0]) if isinstance(label, (list, np.ndarray)) else str(label)
            )
            for uid, label in zip(
                analyzer.unit_ids,
                bc_unit_labels.reindex(analyzer.unit_ids).values,
            )
        }
    }
    bombcell_file = analyzer_path / "bombcell_labels.json"
    bombcell_file.write_text(json.dumps(bombcell_dict, indent=4))
    print(f"Bombcell labels saved to: {bombcell_file.name}")

    passing_qc_dict = {
        _int(uid): bool(pq) for uid, pq in zip(analyzer.unit_ids, passing_qc)
    }
    passing_qc_file = analyzer_path / "passing_qc.json"
    passing_qc_file.write_text(json.dumps(passing_qc_dict, indent=4))
    print(f"passing_qc saved to: {passing_qc_file.name}")

    print(f"\nAdvanced curation complete for {sorter_name}.")


if __name__ == "__main__":
    main()

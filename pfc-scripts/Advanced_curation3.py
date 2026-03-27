#%%
from pathlib import Path
import pandas as pd
import numpy as np
import json

import spikeinterface.full as si
import spikeinterface.curation as sc
from spikeinterface.curation.curation_model import CurationModel
from spikeinterface.curation import validate_curation_dict



# Load SortingAnalyzer
analyzer_folder = Path('/Users/pierre/Desktop/analyzer_kilosort4')
curation_file = analyzer_folder / "curation.json"
unitrefine_file = analyzer_folder / "unitrefine_labels.json"
bombcell_file = analyzer_folder / "bombcell_labels.json"

if analyzer_folder.is_dir():
    print("Loading analyzer from disk")
    analyzer = si.load(analyzer_folder, load_extensions=True)
    
# Compute quality metrics if not already present
if analyzer.get_extension("quality_metrics") is None:
    print("Computing quality metrics...")
    analyzer.compute("quality_metrics")
    #analyzer.compute("quality_metrics", metric_names=[
    #"amplitude_cutoff",
    #"presence_ratio", 
    #"isi_violation",
    #"rp_violation",
    #"snr",
    #"firing_rate",
    #"noise_cutoff",
    #"sliding_rp_violation",
    #"firing_range",
    #"sd_ratio",
    #"synchrony",
    #])
    print("Done.")   
    


if curation_file.exists():
    # --------------------------------------------------------
    # RESUME: load existing curation, skip all auto steps
    # --------------------------------------------------------
    print("Found curation.json — resuming manual curation")
    curation_dict = json.loads(curation_file.read_text())

    # Restore unitrefine properties onto analyzer, reindexed by unit_id
    if unitrefine_file.exists():
        unitrefine_dict = json.loads(unitrefine_file.read_text())
        pred_map = unitrefine_dict["unitrefine_prediction"]
        prob_map = unitrefine_dict["unitrefine_probability"]

        predictions = np.array(
            [pred_map.get(str(uid), "unknown") for uid in analyzer.unit_ids], dtype="U10"
        )
        probabilities = np.array(
            [prob_map.get(str(uid), 0.0) for uid in analyzer.unit_ids], dtype=float
        )
        analyzer.set_sorting_property("unitrefine_prediction", predictions)
        analyzer.set_sorting_property("unitrefine_probability", probabilities)
        print("Restored unitrefine labels from unitrefine_labels.json")

    # Restore bombcell labels
    if bombcell_file.exists():
        bombcell_dict = json.loads(bombcell_file.read_text())
        label_map = bombcell_dict["bombcell_label"]
        bc_labels = np.array(
            [label_map.get(str(uid), "unknown") for uid in analyzer.unit_ids], dtype="U10"
        )
        analyzer.set_sorting_property("bombcell_label", bc_labels)
        print("Restored bombcell labels from bombcell_labels.json")

    # Restore passing_qc
    passing_qc_file = analyzer_folder / "passing_qc.json"
    if passing_qc_file.exists():
        passing_qc_dict = json.loads(passing_qc_file.read_text())
        passing_qc = np.array(
            [passing_qc_dict.get(str(uid), False) for uid in analyzer.unit_ids], dtype=bool
        )
        analyzer.set_sorting_property("passing_qc", passing_qc)
        print("Restored passing_qc from passing_qc.json")

else:
    # --------------------------------------------------------
    # FRESH RUN: run all auto curation steps
    # --------------------------------------------------------
    print("No curation.json found — running auto curation pipeline")

    # Remove redundant units
    sorting_clean = sc.remove_redundant_units(analyzer)
    if len(sorting_clean.unit_ids) < len(analyzer.unit_ids):
        num_redundant = len(analyzer.unit_ids) - len(sorting_clean.unit_ids)
        print(f"Found {num_redundant} redundant units")
        analyzer = analyzer.select_units(sorting_clean.unit_ids)

    num_uncurated_units = len(analyzer.unit_ids)

    # Quality metrics based curation
    qm = analyzer.get_extension("quality_metrics").get_data()
    print(f"Available metrics: {qm.columns.values}")

    curation_query = "amplitude_cutoff < 0.1 and presence_ratio > 0.95 and isi_violations_ratio < 1"
    qm_filtered = qm.query(curation_query)
    print(f"Number of units after QM curation: {len(qm_filtered)} / {len(qm)}")

    units_to_keep = list(qm_filtered.index)
    passing_qc = np.zeros(len(analyzer.unit_ids), dtype=bool)
    passing_qc[analyzer.sorting.ids_to_indices(units_to_keep)] = True
    analyzer.set_sorting_property("passing_qc", passing_qc)

    # UnitRefine — noise/neuron classifier
    noise_neuron_labels = sc.model_based_label_units(
        sorting_analyzer=analyzer,
        repo_id="SpikeInterface/UnitRefine_noise_neural_classifier_lightweight",
        trust_model=True,
    )

    noise_units = noise_neuron_labels[noise_neuron_labels['prediction'] == 'noise']
    neural_units = noise_neuron_labels[noise_neuron_labels['prediction'] != 'noise']
    analyzer_neural = analyzer.select_units(list(neural_units.index), keep_all_extensions=True)

    # UnitRefine — SUA/MUA classifier
    sua_mua_labels = sc.model_based_label_units(
        sorting_analyzer=analyzer_neural,
        repo_id="SpikeInterface/UnitRefine_sua_mua_classifier_lightweight",
        trust_model=True,
    )

    unit_refine_labels = pd.concat([sua_mua_labels, noise_units]).sort_index()
    sua_units = sua_mua_labels[sua_mua_labels['prediction'] == 'sua']
    mua_units = sua_mua_labels[sua_mua_labels['prediction'] == 'mua']

    print(f"Noise units: {len(noise_units)} / {num_uncurated_units}")
    print(f"MUA units:   {len(mua_units)} / {num_uncurated_units}")
    print(f"SUA units:   {len(sua_units)} / {num_uncurated_units}")

    # Bombcell labels
    available = set(qm.columns)
    thresholds = sc.bombcell_get_default_thresholds()
    for category in thresholds.values():
        keys_to_remove = [m for m in list(category.keys()) if m not in available]
        for m in keys_to_remove:
            category.pop(m)

    bc_unit_labels = sc.bombcell_label_units(sorting_analyzer=analyzer, thresholds=thresholds)
    bc_labels_array = np.array(bc_unit_labels.reindex(analyzer.unit_ids).values, dtype="U10")
    analyzer.set_sorting_property("bombcell_label", bc_labels_array)

    sua_bc  = np.sum(bc_unit_labels == "good")
    mua_bc  = np.sum(bc_unit_labels == "mua")
    noise_bc = np.sum(bc_unit_labels == "noise")
    print(f"Bombcell — good: {sua_bc} / MUA: {mua_bc} / noise: {noise_bc} out of {num_uncurated_units}")

    # Store as properties for GUI columns (dtype U10 required for GUI rendering)
    analyzer.set_sorting_property(
        "unitrefine_prediction",
        np.array(unit_refine_labels["prediction"].reindex(analyzer.unit_ids).values, dtype="U10")
    )
    analyzer.set_sorting_property(
        "unitrefine_probability",
        np.array(unit_refine_labels["probability"].reindex(analyzer.unit_ids).values, dtype=float)
    )

    # Auto merge
    potential_merges = sc.compute_merge_unit_groups(
        analyzer_neural,
        preset="similarity_correlograms",
        steps_params={"template_similarity": {"template_diff_thresh": 0.5}}
    )
    print(f"Potential merges: {potential_merges}")

    # Build curation dict (standard keys only)
    label_definitions = {
        "quality": dict(name="quality", label_options=["good", "MUA", "noise"], exclusive=True),
    }
    curation_dict = dict(
        format_version="2",
        unit_ids=[int(u) if isinstance(u, np.integer) else u for u in analyzer.unit_ids],
        label_definitions=label_definitions,
        merges=[dict(unit_ids=[int(u) if isinstance(u, np.integer) else u for u in p]) for p in potential_merges],
        removed=[int(u) if isinstance(u, np.integer) else u for u in noise_units.index],
        manual_labels=[],
    )

    # Validate and save curation.json
    validate_curation_dict(curation_dict)
    curation = CurationModel(**curation_dict)
    curation_file.write_text(curation.model_dump_json(indent=4))
    print(f"Curation saved to {curation_file}")

    # Save unitrefine labels keyed by unit_id for safe resume
    unitrefine_dict = {
        "unitrefine_prediction": {
            int(uid): pred
            for uid, pred in zip(
                analyzer.unit_ids,
                unit_refine_labels["prediction"].reindex(analyzer.unit_ids).values
            )
        },
        "unitrefine_probability": {
            int(uid): float(prob)
            for uid, prob in zip(
                analyzer.unit_ids,
                unit_refine_labels["probability"].reindex(analyzer.unit_ids).values
            )
        },
    }
    unitrefine_file.write_text(json.dumps(unitrefine_dict, indent=4))
    print(f"UnitRefine labels saved to {unitrefine_file}")

    # Save bombcell labels for safe resume
    bombcell_dict = {
    "bombcell_label": {
        int(uid): str(label[0]) if isinstance(label, (list, np.ndarray)) else str(label)
        for uid, label in zip(
            analyzer.unit_ids,
            bc_unit_labels.reindex(analyzer.unit_ids).values
            )
        }
    }
    bombcell_file.write_text(json.dumps(bombcell_dict, indent=4))
    print(f"Bombcell labels saved to {bombcell_file}")

    # Save passing_qc for safe resume
    passing_qc_file = analyzer_folder / "passing_qc.json"
    passing_qc_dict = {
        int(uid): bool(pq)
        for uid, pq in zip(analyzer.unit_ids, passing_qc)
    }
    passing_qc_file.write_text(json.dumps(passing_qc_dict, indent=4))
    print(f"passing_qc saved to {passing_qc_file}")

#  Launch GUI (always runs)
with open('/Users/pierre/.config/spikeinterface_gui/0.12.1/settings/quality_settings.json', 'r') as f:
    settings_dict = json.load(f)
with open('/Users/pierre/.config/spikeinterface_gui/0.12.1/layouts/layout_quality.json', 'r') as f:
    layout_dict = json.load(f)

from spikeinterface_gui import run_mainwindow
run_mainwindow(
    analyzer,
    mode="desktop",
    extra_unit_properties={
        "passing_qc": analyzer.sorting.get_property("passing_qc"),
        "unitrefine_prediction": np.array(analyzer.sorting.get_property("unitrefine_prediction"), dtype="U10"),
        "unitrefine_probability": analyzer.sorting.get_property("unitrefine_probability"),
        "KSLabel": np.array(analyzer.sorting.get_property("KSLabel"), dtype="U10"),
        "bombcell_label": np.array(analyzer.sorting.get_property("bombcell_label"), dtype="U10"),
    },
    curation=True,
    curation_dict=curation_dict,
    layout=layout_dict,
    user_settings=settings_dict
)

# %%
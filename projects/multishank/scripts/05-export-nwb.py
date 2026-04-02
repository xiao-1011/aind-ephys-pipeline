"""Step 5: Export curated sorting results to NWB.

Creates a minimal NWB file containing:
  - Electrode table (channel IDs and locations from the preprocessed recording)
  - Units table (spike times + quality metrics for auto-curated 'good' units)

Subject / session metadata are placeholders for now.
TODO: populate from the lab metadata file once it is available on the server.
"""
from pathlib import Path
import argparse
import json
from datetime import datetime
from dateutil.tz import tzlocal

import numpy as np
import pynwb
import spikeinterface.full as si


def _consensus_description(output_folder: Path) -> str:
    """Build the in_consensus column description from consensus_labels.json if present."""
    consensus_path = output_folder / "consensus_labels.json"
    if consensus_path.is_file():
        with open(consensus_path) as f:
            cl = json.load(f)
        thr = cl.get('agreement_threshold', 0.5)
        min_agr = cl.get('min_agreement', 2)
        sorters = cl.get('sorters', [])
        n = len(sorters)
        return (
            f"Unit matched by ≥{min_agr} of {n} sorters "
            f"(spike-overlap ≥ {thr * 100:.0f}%)"
        )
    return "Unit found by multiple sorters (consensus)"


def build_nwb(
    output_folder: Path,
    session_id: str,
    probe_id: str,
    curation_file: Path,
    sorter_folder: Path,
    preprocessed_folder: Path,
) -> Path:
    print(f"  Loading curation labels from: {curation_file.name}")
    with open(curation_file) as f:
        curation = json.load(f)

    labels = curation["labels"]
    qm_table = curation["quality_metrics"]
    sorter_name = curation["sorter"]

    good_unit_ids_str = [uid for uid, lbl in labels.items() if lbl == "good"]
    if not good_unit_ids_str:
        print("  No good units after curation — skipping NWB export.")
        return None

    print(f"  Loading recording from: {preprocessed_folder.name}")
    recording = si.load(preprocessed_folder)
    fs = recording.get_sampling_frequency()

    print(f"  Loading sorting from: {sorter_folder.name}")
    sorting = si.load_extractor(sorter_folder)

    # Cast unit IDs to the type used by the sorting object
    all_ids = sorting.get_unit_ids()
    id_type = type(all_ids[0])
    try:
        good_unit_ids = [id_type(uid) for uid in good_unit_ids_str]
    except (ValueError, TypeError):
        good_unit_ids = good_unit_ids_str

    # Determine quality metric column names from the first unit that has data
    qm_columns = []
    for uid_str in good_unit_ids_str:
        row = qm_table.get(uid_str, {})
        if row:
            qm_columns = list(row.keys())
            break

    consensus_map = curation.get("consensus") or {}  # uid_str → bool (empty if not available)

    # ── Build NWB file ───────────────────────────────────────────────────────
    nwbfile = pynwb.NWBFile(
        session_description=(
            f"Electrophysiology: session {session_id}, probe {probe_id}. "
            f"Spike-sorted with {sorter_name}, auto-curated."
        ),
        identifier=f"{session_id}_{probe_id}_{sorter_name}",
        session_start_time=datetime.now(tzlocal()),  # TODO: replace with actual session time
        experimenter="Unknown",                       # TODO: from metadata
        lab="DMC Lab",
        institution="Karolinska Institutet",
    )

    # Device and electrode group
    device = nwbfile.create_device(
        name="Neuropixels",
        description="Neuropixels probe (IMEC)",
        manufacturer="IMEC",
    )
    electrode_group = nwbfile.create_electrode_group(
        name=probe_id,
        description=f"Probe {probe_id}",
        location="unknown",  # TODO: from metadata
        device=device,
    )

    # Electrode table — one row per channel
    channel_ids = recording.channel_ids
    locations = recording.get_property("location")  # (n_channels, 2) array or None

    for i, ch_id in enumerate(channel_ids):
        x = float(locations[i][0]) if locations is not None else float("nan")
        y = float(locations[i][1]) if locations is not None else float("nan")
        nwbfile.add_electrode(
            group=electrode_group,
            location="unknown",
            x=x,
            y=y,
            filtering="bandpass 300–6000 Hz",
        )

    electrode_region = nwbfile.create_electrode_table_region(
        region=list(range(len(channel_ids))),
        description="all recorded channels",
    )

    # Units table columns
    nwbfile.add_unit_column(name="quality", description="Auto-curation label (good/bad)")
    if consensus_map:
        nwbfile.add_unit_column(
            name="in_consensus",
            description=_consensus_description(output_folder),
        )
    for col in qm_columns:
        nwbfile.add_unit_column(name=col, description=f"Quality metric: {col}")

    # Add one row per good unit
    for uid in good_unit_ids:
        uid_str = str(uid)
        spike_train = sorting.get_unit_spike_train(uid, segment_index=0)
        spike_times = spike_train / fs

        unit_kwargs = {
            "spike_times": spike_times,
            "quality": "good",
        }
        if consensus_map:
            unit_kwargs["in_consensus"] = bool(consensus_map.get(uid_str, False))
        row = qm_table.get(uid_str, {})
        for col in qm_columns:
            val = row.get(col, None)
            unit_kwargs[col] = float("nan") if val is None else float(val)

        nwbfile.add_unit(**unit_kwargs)

    nwb_path = output_folder / f"{session_id}_{probe_id}_{sorter_name}.nwb"
    with pynwb.NWBHDF5IO(str(nwb_path), "w") as io:
        io.write(nwbfile)

    n_units = len(good_unit_ids)
    print(f"  NWB written: {nwb_path.name}  ({n_units} units)")
    return nwb_path


def main():
    parser = argparse.ArgumentParser(
        description="Step 5: Export curated units to NWB",
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument("output_folder", type=str,
                        help="Path to output folder (same as previous steps)")
    parser.add_argument("--session-id", type=str, default=None,
                        help="Session identifier (defaults to parent folder name)")
    parser.add_argument("--probe-id", type=str, default=None,
                        help="Probe identifier (defaults to output_folder name)")
    args = parser.parse_args()

    output_folder = Path(args.output_folder)
    session_id = args.session_id or output_folder.parent.name
    probe_id   = args.probe_id   or output_folder.name

    preprocessed_folder = output_folder / "preprocessed"
    if not preprocessed_folder.is_dir():
        raise FileNotFoundError(f"Preprocessed recording not found: {preprocessed_folder}")

    curation_files = sorted(output_folder.glob("curation_*.json"))
    if not curation_files:
        raise FileNotFoundError(
            f"No 'curation_*.json' files found in: {output_folder}\n"
            "Please run 04-curate.py first."
        )

    for curation_file in curation_files:
        sorter_name = curation_file.stem.replace("curation_", "", 1)
        sorter_folder = output_folder / f"sorter_{sorter_name}"
        if not sorter_folder.is_dir():
            print(f"  Sorter folder not found for '{sorter_name}' — skipping.")
            continue

        print(f"\nExporting NWB for: {sorter_name}")
        build_nwb(
            output_folder=output_folder,
            session_id=session_id,
            probe_id=probe_id,
            curation_file=curation_file,
            sorter_folder=sorter_folder,
            preprocessed_folder=preprocessed_folder,
        )

    print("\nNWB export complete.")


if __name__ == "__main__":
    main()

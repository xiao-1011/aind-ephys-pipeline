from pathlib import Path
import argparse
import resource
from concurrent.futures import ProcessPoolExecutor, as_completed

import spikeinterface.full as si
import spikeinterface.preprocessing as spre
from spikeinterface.sortingcomponents.motion import interpolate_motion

MAX_PARALLEL_SHANKS = 4


def preprocess_shank(recording, shank_label, working_folder, filter_type,
                     use_spatial_filter, apply_motion):
    """Preprocess a single shank (or the whole probe if single-shank).

    Chain: phase_shift -> filter -> bad_channel_detect(coherence+psd) -> CMR
           -> spatial_filter(optional) -> motion(compute + optional apply)
    """

    preprocessed_folder = working_folder / f"preprocessed_{shank_label}"
    if preprocessed_folder.is_dir():
        print(f"  [{shank_label}] Preprocessed recording already exists -- skipping.")
        return

    print(f"  [{shank_label}] {recording.get_num_channels()} channels")

    rec = recording.astype('float32')

    # 1. Phase shift (correct inter-sample ADC delays)
    rec = spre.phase_shift(rec)

    # 2. Filter
    if filter_type == 'bandpass':
        rec = spre.bandpass_filter(rec, freq_min=300.0, freq_max=6000.0)
    else:
        rec = spre.highpass_filter(rec, freq_min=300.0)

    # 3. Bad channel detection (coherence+psd — more robust than default)
    bad_ids, bad_labels = spre.detect_bad_channels(
        rec,
        method='coherence+psd',
        dead_channel_threshold=-0.5,
        noisy_channel_threshold=1.0,
        outside_channel_threshold=-0.3,
        outside_channels_location='top',
        n_neighbors=11,
        seed=0,
    )
    print(f"  [{shank_label}] Bad channels: {len(bad_ids)} "
          f"({dict(zip(bad_ids, bad_labels))})")

    rec = rec.remove_channels(bad_ids)

    if rec.get_num_channels() == 0:
        raise RuntimeError(f"[{shank_label}] All channels removed as bad!")

    # 4. Common median reference (per-shank — critical for multi-shank)
    rec = spre.common_reference(rec, reference='global', operator='median')

    # 5. Highpass spatial filter with AGC (optional)
    if use_spatial_filter:
        rec = spre.highpass_spatial_filter(
            rec,
            n_channel_pad=60,
            n_channel_taper=None,
            direction='y',
            apply_agc=True,
            agc_window_length_s=0.01,
            highpass_butter_order=3,
            highpass_butter_wn=0.01,
        )

    # 6. Motion correction
    preset = 'dredge_fast'
    motion_folder = working_folder / f"motion_{preset}_{shank_label}"
    rec = rec.astype('float32')

    if motion_folder.is_dir():
        print(f"  [{shank_label}] Loading motion from disk...")
        motion_info_ = si.load_motion_info(motion_folder)
        motion = motion_info_['motion']
    else:
        print(f"  [{shank_label}] Computing drift with preset '{preset}'...")
        motion, motion_info = si.compute_motion(
            recording=rec,
            preset=preset,
            output_motion_info=True,
        )
        si.save_motion_info(motion_info, folder=motion_folder)
        motion = motion_info['motion']

    if apply_motion:
        print(f"  [{shank_label}] Applying motion correction...")
        rec = interpolate_motion(recording=rec, motion=motion)

    # 7. Save
    print(f"  [{shank_label}] Saving preprocessed recording...")
    recording_preprocessed = rec.astype('int16')
    recording_preprocessed.save(folder=preprocessed_folder, format='binary')

    peak_gb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 ** 2)
    print(f"  [{shank_label}] Done. Peak RSS: {peak_gb:.1f} GB. Saved to: {preprocessed_folder}")


def main():
    parser = argparse.ArgumentParser(
        description='Step 1: Preprocess SpikeGLX recording (multi-shank aware)')
    parser.add_argument('data_folder', type=str,
                        help='Path to recording folder (e.g., .../999770_day3_g0_imec0)')
    parser.add_argument('output_folder', type=str,
                        help='Path to output folder')
    parser.add_argument('--filter-type', choices=['highpass', 'bandpass'],
                        default='bandpass',
                        help='Filter type (default: bandpass)')
    parser.add_argument('--spatial-filter', action='store_true', default=True,
                        help='Enable highpass spatial filter with AGC (default)')
    parser.add_argument('--no-spatial-filter', dest='spatial_filter',
                        action='store_false',
                        help='Disable highpass spatial filter')
    parser.add_argument('--apply-motion', action='store_true', default=True,
                        help='Apply motion correction interpolation (default)')
    parser.add_argument('--no-apply-motion', dest='apply_motion',
                        action='store_false',
                        help='Compute motion but do not apply interpolation')
    parser.add_argument('--max-duration-sec', type=int, default=0,
                        help='Truncate recording to first N seconds (0 = full recording)')
    args = parser.parse_args()

    n_jobs = 128 // MAX_PARALLEL_SHANKS  # split cores evenly across parallel shanks
    global_job_kwargs = dict(n_jobs=n_jobs, mp_context='fork', progress_bar=True)
    si.set_global_job_kwargs(**global_job_kwargs)

    spikeglx_folder = Path(args.data_folder)
    working_folder = Path(args.output_folder)
    working_folder.mkdir(parents=True, exist_ok=True)

    recording_name = spikeglx_folder.name

    # Determine stream name from folder name
    stream = None
    for part in recording_name.split('_'):
        if part.startswith('imec'):
            stream = part
            break
    if stream is None:
        raise ValueError(f"No 'imec' found in folder name: {recording_name}")
    stream_name = f"{stream}.ap"

    print(f"Recording name:   {recording_name}")
    print(f"Data folder:      {spikeglx_folder}")
    print(f"Stream:           {stream_name}")
    print(f"Output folder:    {working_folder}")
    print(f"Filter type:      {args.filter_type}")
    print(f"Spatial filter:   {args.spatial_filter}")
    print(f"Apply motion:     {args.apply_motion}")

    print("Loading data...")
    raw_rec = si.read_spikeglx(spikeglx_folder, stream_name=stream_name,
                                load_sync_channel=False)

    if args.max_duration_sec > 0:
        t_start = raw_rec.get_times()[0]
        end_sec = min(args.max_duration_sec, raw_rec.get_total_duration())
        raw_rec = raw_rec.time_slice(start_time=t_start, end_time=t_start + end_sec)
        print(f"  TEST MODE: truncated to {end_sec:.0f}s ({raw_rec.get_num_frames()} frames)")

    # Detect channel groups (shanks)
    groups = raw_rec.get_channel_groups()
    unique_groups = sorted(set(groups))
    print(f"Detected {len(unique_groups)} group(s): {unique_groups}")

    if len(unique_groups) <= 1:
        # Single shank (or no group info) — process as shank0
        print("Single group detected — processing as shank0")
        preprocess_shank(raw_rec, 'shank0', working_folder,
                         args.filter_type, args.spatial_filter, args.apply_motion)
    else:
        # Multi-shank — split by group and process in parallel (2 at a time)
        rec_dict = raw_rec.split_by('group')
        with ProcessPoolExecutor(max_workers=MAX_PARALLEL_SHANKS) as executor:
            futures = {}
            for group_id in unique_groups:
                shank_label = f"shank{group_id}"
                print(f"\nSubmitting {shank_label}...")
                fut = executor.submit(
                    preprocess_shank, rec_dict[group_id], shank_label,
                    working_folder, args.filter_type, args.spatial_filter,
                    args.apply_motion)
                futures[fut] = shank_label
            for fut in as_completed(futures):
                label = futures[fut]
                try:
                    fut.result()
                except Exception as e:
                    print(f"\nERROR processing {label}: {e}")
                    raise

    print("\nPreprocessing complete.")


if __name__ == "__main__":
    main()

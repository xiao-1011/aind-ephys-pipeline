from pathlib import Path
import argparse

import spikeinterface.full as si
import spikeinterface.preprocessing as spre
from spikeinterface.sortingcomponents.motion import interpolate_motion


def main():
    parser = argparse.ArgumentParser(description='Step 1: Preprocess SpikeGLX recording')
    parser.add_argument('data_folder', type=str,
                        help='Path to recording folder (e.g., .../999770_day3_g0_imec0)')
    parser.add_argument('output_folder', type=str,
                        help='Path to output folder')
    args = parser.parse_args()

    global_job_kwargs = dict(n_jobs=20, mp_context='fork', progress_bar=True)
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

    print(f"Recording name: {recording_name}")
    print(f"Data folder:    {spikeglx_folder}")
    print(f"Stream:         {stream_name}")
    print(f"Output folder:  {working_folder}")

    preprocessed_folder = working_folder / "preprocessed"

    if preprocessed_folder.is_dir():
        print("Preprocessed recording already exists — skipping.")
        return

    print("Loading data...")
    raw_rec = si.read_spikeglx(spikeglx_folder, stream_name=stream_name, load_sync_channel=False)

    print("Preprocessing...")
    raw_rec = raw_rec.astype('float32')
    shifted = spre.phase_shift(raw_rec)
    referenced = spre.common_reference(shifted, reference="global", operator="median")
    filtered = spre.bandpass_filter(referenced, freq_min=300.0, freq_max=6000.0)
    good_channels = spre.detect_and_remove_bad_channels(filtered)

    # Motion correction
    preset = "dredge_fast"
    motion_folder = working_folder / f"motion_{preset}"
    good_channels = good_channels.astype('float32')

    if motion_folder.is_dir():
        print("Loading motion from disk...")
        motion_info_ = si.load_motion_info(motion_folder)
        motion = motion_info_["motion"]
    else:
        print(f"Computing drift with preset '{preset}'...")
        motion, motion_info = si.compute_motion(
            recording=good_channels,
            preset=preset,
            output_motion_info=True,
        )
        si.save_motion_info(motion_info, folder=motion_folder)
        motion = motion_info['motion']

    print("Applying motion correction and saving preprocessed recording...")
    interpolated = interpolate_motion(recording=good_channels, motion=motion)
    recording_preprocessed = interpolated.astype('int16')
    recording_preprocessed.save(folder=preprocessed_folder, format="binary")

    print(f"Preprocessing complete. Saved to: {preprocessed_folder}")


if __name__ == "__main__":
    main()

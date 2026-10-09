"""Synthetic checks for exact contextual replay validation; run in pipeline-base."""

import unittest

import numpy as np

from ks4_motion_trace_recover import verify_saved


class FakeRecording:
    sampling_frequency = 1
    dtype = np.dtype("float32")

    def __init__(self, offset, short_window_change=0.0, nan=False, shifted=False):
        self.offset = offset
        self.short_window_change = short_window_change
        self.nan = nan
        self.shifted = shifted
        self.channel_ids = np.arange(3)

    def get_num_segments(self):
        return 1

    def get_num_frames(self):
        return 2000

    def get_times(self):
        return np.arange(2000)

    def get_traces(self, start_frame, end_frame):
        frames = np.arange(start_frame + int(self.shifted), end_frame + int(self.shifted))[:, None]
        data = (frames * 0.001 + self.channel_ids + self.offset).astype("float32")
        if end_frame - start_frame == 100:
            data[:, -1] += self.short_window_change
        if self.nan:
            data[0, 0] = np.nan
        return data


class ContextualTraceTests(unittest.TestCase):
    def setUp(self):
        self.original = FakeRecording(0)
        self.saved = FakeRecording(1)
        self.live = FakeRecording(1, short_window_change=1e-5)

    def test_exact_context_succeeds_even_when_short_windows_differ(self):
        self.assertFalse(np.array_equal(self.saved.get_traces(30, 130), self.live.get_traces(30, 130)))
        result = verify_saved(self.saved, self.live, self.original)
        self.assertEqual(result["exact_contextual_windows"], 25)
        self.assertGreater(result["max_change_from_uncorrected"], 0)

    def test_shift_is_not_accepted(self):
        with self.assertRaises(AssertionError):
            verify_saved(FakeRecording(1, shifted=True), self.live, self.original)

    def test_nonfinite_values_are_not_accepted(self):
        with self.assertRaises(AssertionError):
            verify_saved(self.saved, FakeRecording(1, nan=True), self.original)


if __name__ == "__main__":
    unittest.main()

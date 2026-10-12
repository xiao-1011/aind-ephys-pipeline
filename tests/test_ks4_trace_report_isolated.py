"""Fail-closed, non-overwriting report staging without cluster dependencies."""

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from ks4_motion_trace_report_isolated import SESSIONS, stage


class IsolatedReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.test = Path(self.tmp.name) / "test"
        self.test.mkdir()
        (self.test / "model_provenance.json").write_text("{}")
        self.report = self.test / "report_20261009"
        for rel in SESSIONS:
            for group in range(4):
                root = self.test / rel / f"group{group}"
                root.mkdir(parents=True)
                (root / "curation_complete").write_text("passed\n")
                (root / "heldout_waveform_stability.csv").write_text("unit_id,trace\n")
                name = f"block0_imec0.ap_recording1_group{group}"
                for arm in ("uncorrected", "native_motion_interpolated"):
                    data = root / arm
                    analyzer = data / "postprocessing/capsule/results" / f"postprocessed_{name}.zarr"
                    analyzer.mkdir(parents=True)
                    (analyzer / "keep").write_text("retained")
                    labels = data / "curation/capsule/results" / f"unit_labels_{name}.csv"
                    labels.parent.mkdir(parents=True)
                    labels.write_text("default_qc\nTrue\n")

    def tearDown(self):
        self.tmp.cleanup()

    def test_missing_input_does_not_create_report(self):
        missing = self.test / SESSIONS[1] / "group1/curation_complete"
        missing.unlink()
        with self.assertRaisesRegex(AssertionError, "Incomplete replay"):
            stage(self.test, self.report)
        self.assertFalse(self.report.exists())

    def test_staging_never_writes_to_original_inputs(self):
        stage(self.test, self.report)
        source = self.test / SESSIONS[0] / "group0/curation_complete"
        target = self.report / SESSIONS[0] / "group0/curation_complete"
        self.assertTrue(target.is_symlink())
        self.assertEqual(target.read_text(), source.read_text())
        (target.parent / "historical_unit_labels.csv").write_text("new report only\n")
        self.assertFalse((source.parent / "historical_unit_labels.csv").exists())

    def test_existing_report_is_not_overwritten(self):
        self.report.mkdir()
        sentinel = self.report / "keep"
        sentinel.write_text("user data")
        with self.assertRaises(AssertionError):
            stage(self.test, self.report)
        self.assertEqual(sentinel.read_text(), "user data")


if __name__ == "__main__":
    unittest.main()

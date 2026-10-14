"""Safety tests runnable without cluster/SpikeInterface dependencies."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import archive_session
import arrhenius_batch


class ArchiveSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def archive(self, entries):
        path = self.root / "test.tar"
        with tarfile.open(path, "w") as tar:
            for name, data, kind in entries:
                info = tarfile.TarInfo(name)
                info.type = kind
                if kind == tarfile.REGTYPE:
                    info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))
                else:
                    info.linkname = "/etc/passwd"
                    tar.addfile(info)
        return path

    def verify(self, archive):
        stage = self.root / "stage"
        stage.mkdir()
        return archive_session.restore_verify(archive, stage)

    def test_verified_content_round_trip(self):
        data = b"corrected recording"
        manifest = {"files": {"data.bin": {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}}}
        archive = self.archive([("session/archive_manifest.json", json.dumps(manifest).encode(), tarfile.REGTYPE),
                                ("session/data.bin", data, tarfile.REGTYPE)])
        with patch.object(archive_session, "verify_bundle") as check:
            self.assertEqual(self.verify(archive), manifest)
            check.assert_called_once()

    def test_corrupt_content_never_passes_restore_check(self):
        manifest = {"files": {"data.bin": {"size": 3, "sha256": hashlib.sha256(b"abc").hexdigest()}}}
        archive = self.archive([("session/archive_manifest.json", json.dumps(manifest).encode(), tarfile.REGTYPE),
                                ("session/data.bin", b"bad", tarfile.REGTYPE)])
        with patch.object(archive_session, "verify_bundle") as check:
            with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
                self.verify(archive)
            check.assert_not_called()

    def test_rejects_path_traversal(self):
        with self.assertRaisesRegex(RuntimeError, "Unsafe archive member"):
            self.verify(self.archive([("session/../../outside", b"bad", tarfile.REGTYPE)]))

    def test_rejects_symlinks(self):
        with self.assertRaisesRegex(RuntimeError, "Unsupported archive member"):
            self.verify(self.archive([("session/link", b"", tarfile.SYMTYPE)]))

    def test_rejects_duplicate_members(self):
        with self.assertRaisesRegex(RuntimeError, "Duplicate archive member"):
            self.verify(self.archive([("session/data", b"a", tarfile.REGTYPE),
                                      ("session/data", b"b", tarfile.REGTYPE)]))

    def test_cleanup_only_deletes_owned_session(self):
        root = self.root / "work"
        target = root / "cohort/date/session"
        target.mkdir(parents=True)
        (target / "data").write_text("temporary")
        protected = self.root / "raw/cohort/date/session"
        protected.mkdir(parents=True)
        with self.assertRaises(RuntimeError):
            arrhenius_batch.remove_owned(protected, root, "cohort/date/session")
        with self.assertRaises(RuntimeError):
            arrhenius_batch.remove_owned(root, root, ".")
        arrhenius_batch.remove_owned(target, root, "cohort/date/session")
        self.assertFalse(target.exists())
        self.assertTrue(protected.exists())
        self.assertTrue(root.exists())

    def test_cleanup_rejects_external_symlink(self):
        root = self.root / "work"
        (root / "cohort/date").mkdir(parents=True)
        outside = self.root / "raw"
        outside.mkdir()
        target = root / "cohort/date/session"
        target.symlink_to(outside)
        with self.assertRaises(RuntimeError):
            arrhenius_batch.remove_owned(target, root, "cohort/date/session")
        self.assertTrue(outside.exists())

    def test_expected_motion_for_dredge(self):
        params = {"preprocessing": {"motion_correction": {"compute": True, "apply": True}},
                  "spikesorting": {"kilosort4": {"skip_motion_correction": True,
                                               "min_drift_channels": 64, "sorter": {"do_correction": True}}}}
        self.assertEqual(archive_session.expected_motion(params, 80), (True, False))

    def test_expected_motion_for_ks4_and_low_channel_shank(self):
        params = {"preprocessing": {"motion_correction": {"compute": False, "apply": False}},
                  "spikesorting": {"kilosort4": {"skip_motion_correction": False,
                                               "min_drift_channels": 64, "sorter": {"do_correction": True}}}}
        self.assertEqual(archive_session.expected_motion(params, 80), (False, True))
        self.assertEqual(archive_session.expected_motion(params, 63), (False, False))
        self.assertEqual(archive_session.expected_motion(params, 64), (False, True))

    def test_rejects_double_correction(self):
        params = {"preprocessing": {"motion_correction": {"compute": True, "apply": True}},
                  "spikesorting": {"kilosort4": {"skip_motion_correction": False,
                                               "min_drift_channels": 64, "sorter": {"do_correction": True}}}}
        with self.assertRaisesRegex(RuntimeError, "Two motion correction paths"):
            archive_session.expected_motion(params, 80)

    def test_batch_requires_report_for_every_existing_archive(self):
        raw = self.root / "raw_ecephys/cohort/date/session"
        raw.mkdir(parents=True)
        (raw / "recording.ap.bin").write_bytes(b"data")
        archive_root = self.root / "session_archives/ks4_baseline"
        archive = archive_root / "cohort/date/session.tar"
        archive.parent.mkdir(parents=True)
        archive.write_bytes(b"retained")
        args = SimpleNamespace(user_root=self.root, archive_root=archive_root, pilot_report=[],
                               session=None, curation_sif=None)
        with self.assertRaisesRegex(RuntimeError, "verification report for each existing archive"):
            arrhenius_batch.start(args)
        self.assertFalse((self.root / "batch_runs").exists())

    def test_batch_rejects_duplicate_pilot_reports(self):
        report = self.root / "pilot.json"
        report.write_text(json.dumps({"raw": "duplicate"}))
        args = SimpleNamespace(user_root=self.root, archive_root=self.root / "session_archives/test", pilot_report=[report, report],
                               session=None, curation_sif=None)
        with self.assertRaisesRegex(RuntimeError, "Duplicate pilot reports"):
            arrhenius_batch.start(args)

    def test_batch_requires_named_archive_root(self):
        self.raw_sessions("c/d/a")
        for root in (None, self.root / "session_archives", self.root / "elsewhere"):
            args = SimpleNamespace(user_root=self.root, archive_root=root, pilot_report=[],
                                   session=None, curation_sif=self.image())
            with self.assertRaisesRegex(RuntimeError, "archive-root is required|named folder inside"):
                arrhenius_batch.start(args)
        self.assertFalse((self.root / "batch_runs").exists())

    def raw_sessions(self, *names):
        for name in names:
            raw = self.root / "raw_ecephys" / name
            raw.mkdir(parents=True)
            (raw / "recording.ap.bin").write_bytes(b"data")

    def image(self, data=b"image", checksum=None):
        sif = self.root / "containers/curation.sif"
        sif.parent.mkdir(parents=True, exist_ok=True)
        sif.write_bytes(data)
        checksum = checksum or hashlib.sha256(data).hexdigest()
        (sif.parent / "curation.sif.sha256").write_text(f"{checksum}  {sif}\n")
        return sif

    def test_batch_rejects_unknown_session(self):
        self.raw_sessions("c/d/a")
        args = SimpleNamespace(user_root=self.root, archive_root=self.root / "session_archives/test", pilot_report=[],
                               session=["c/d/missing"], curation_sif=self.image())
        with self.assertRaisesRegex(RuntimeError, "Unknown --session"):
            arrhenius_batch.start(args)
        self.assertFalse((self.root / "batch_runs").exists())

    def test_session_filter_ignores_unselected_existing_archive(self):
        # An unselected session's archive must not demand a pilot report, and the
        # curation image is checked before any batch directory is created.
        self.raw_sessions("c/d/a", "c/d/b")
        archive = self.root / "session_archives/test/c/d/b.tar"
        archive.parent.mkdir(parents=True)
        archive.write_bytes(b"retained")
        args = SimpleNamespace(user_root=self.root, archive_root=self.root / "session_archives/test", pilot_report=[],
                               session=["c/d/a"], curation_sif=self.image(checksum="0" * 64))
        with self.assertRaisesRegex(RuntimeError, "Curation image checksum mismatch"):
            arrhenius_batch.start(args)
        self.assertFalse((self.root / "batch_runs").exists())

    def test_verified_image(self):
        sif = self.image(b"payload")
        self.assertEqual(arrhenius_batch.verified_image(sif), (sif.resolve(), hashlib.sha256(b"payload").hexdigest()))
        (sif.parent / "curation.sif.sha256").unlink()
        with self.assertRaisesRegex(RuntimeError, "Missing curation image or checksum"):
            arrhenius_batch.verified_image(sif)


@unittest.skipUnless(importlib.util.find_spec("pandas"), "pandas not installed")
class MetricCheckTests(unittest.TestCase):
    def test_all_nan_metric_fails(self):
        import pandas as pd

        frames = {"g0": pd.DataFrame({"snr": [float("nan")] * 3, "firing_rate": [1.0, 2.0, 3.0]}),
                  "g1": pd.DataFrame({"snr": [float("nan")], "firing_rate": [1.0]})}
        with self.assertRaisesRegex(RuntimeError, r"\['snr'\]"):
            archive_session.require_finite_metrics(frames)

    def test_metric_finite_in_any_shank_passes(self):
        import pandas as pd

        frames = {"g0": pd.DataFrame({"drift_ptp": [float("nan")] * 2}),
                  "g1": pd.DataFrame({"drift_ptp": [float("nan"), 4.0]})}
        archive_session.require_finite_metrics(frames)

    def test_no_units_fails(self):
        import pandas as pd

        with self.assertRaisesRegex(RuntimeError, "no units"):
            archive_session.require_finite_metrics({"g0": pd.DataFrame({"snr": []})})


if __name__ == "__main__":
    unittest.main()

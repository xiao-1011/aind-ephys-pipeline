"""Safety tests runnable without cluster/SpikeInterface dependencies."""
import hashlib
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
        args = SimpleNamespace(user_root=self.root, archive_root=archive_root, pilot_report=[])
        with self.assertRaisesRegex(RuntimeError, "verification report for each existing archive"):
            arrhenius_batch.start(args)
        self.assertFalse((self.root / "batch_runs").exists())

    def test_batch_rejects_duplicate_pilot_reports(self):
        report = self.root / "pilot.json"
        report.write_text(json.dumps({"raw": "duplicate"}))
        args = SimpleNamespace(user_root=self.root, archive_root=None, pilot_report=[report, report])
        with self.assertRaisesRegex(RuntimeError, "Duplicate pilot reports"):
            arrhenius_batch.start(args)


if __name__ == "__main__":
    unittest.main()

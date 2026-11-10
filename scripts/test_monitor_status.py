import datetime
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from pathlib import Path

import monitor_status


class MonitoringStatusTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dvu-monitor-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.run_id = str(uuid.uuid4())
        self.now = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)

    def read(self, check="database-local"):
        return json.loads((self.directory / f"{check}.json").read_text())

    def record(self, event, run_id=None, now=None):
        monitor_status.record(str(self.directory), "database-local", event, run_id or self.run_id, now or self.now)

    def test_records_success_atomically_without_job_arguments(self):
        self.record("start")
        self.record("success", now=self.now + datetime.timedelta(minutes=1))
        state = self.read()
        self.assertEqual(state["lastOutcome"], "success")
        self.assertEqual(state["lastSuccessAt"], "2026-01-01T00:01:00.000Z")
        self.assertIsNone(state["currentRunId"])
        self.assertEqual((self.directory / "database-local.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual(sorted(self.directory.iterdir()), [
            self.directory / "database-local.json", self.directory / "database-local.lock"
        ])

    def test_older_concurrent_completion_does_not_clear_newer_run(self):
        other = str(uuid.uuid4())
        self.record("start")
        self.record("start", other, self.now + datetime.timedelta(seconds=1))
        self.record("success", self.run_id, self.now + datetime.timedelta(seconds=2))
        self.assertEqual(self.read()["currentRunId"], other)
        self.record("failure", other, self.now + datetime.timedelta(seconds=3))
        state = self.read()
        self.assertEqual(state["lastOutcome"], "failure")
        self.assertEqual(state["lastSuccessAt"], "2026-01-01T00:00:02.000Z")
        self.assertEqual(state["lastFailureAt"], "2026-01-01T00:00:03.000Z")
        self.assertIsNone(state["currentRunId"])

    def test_rejects_unprivate_or_symlinked_state(self):
        self.directory.chmod(0o755)
        with self.assertRaises(monitor_status.MonitoringError):
            self.record("start")
        self.directory.chmod(0o700)
        state = self.directory / "database-local.json"
        state.symlink_to(self.directory / "other")
        with self.assertRaises(OSError):
            self.record("start")

    def test_rejects_invalid_identifiers_and_corrupt_state(self):
        with self.assertRaises(monitor_status.MonitoringError):
            monitor_status.record(str(self.directory), "../outside", "start", self.run_id)
        (self.directory / "database-local.json").write_text("not json")
        (self.directory / "database-local.json").chmod(0o600)
        with self.assertRaises(monitor_status.MonitoringError):
            self.record("start")

    def run_job(self, check, *command, state_dir=None, extra_options=()):
        return subprocess.run(
            [
                sys.executable, str(Path(__file__).with_name("monitor_job.py")),
                "--state-dir", str(state_dir or self.directory), "--check", check, *extra_options, "--", *command,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_wrapper_records_success_and_failure_without_capturing_output(self):
        result = self.run_job("database-local", sys.executable, "-c", "print('job output')")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"job output", result.stdout)
        self.assertEqual(self.read()["lastOutcome"], "success")
        result = self.run_job("database-local", sys.executable, "-c", "raise SystemExit(7)")
        self.assertEqual(result.returncode, 7)
        self.assertEqual(self.read()["lastOutcome"], "failure")
        self.assertIn("lastSuccessAt", self.read())

    def test_wrapper_reports_start_failure_and_does_not_claim_success(self):
        result = self.run_job("database-offsite", "/does-not-exist/dvu-test-command")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read("database-offsite")["lastOutcome"], "failure")
        self.assertIn(b"could not start", result.stderr)

    def test_wrapper_still_runs_job_if_monitoring_is_unavailable(self):
        marker = self.directory / "job-ran"
        result = self.run_job(
            "database-local", sys.executable, "-c",
            "from pathlib import Path; import sys; Path(sys.argv[1]).touch()", str(marker),
            state_dir=self.directory / "missing",
        )
        self.assertTrue(marker.exists())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"could not record monitoring status", result.stderr)

    def test_offsite_wrapper_requires_a_stable_recent_source_archive(self):
        source = self.directory / "archives"
        source.mkdir()
        options = ("--require-archive-dir", str(source))
        marker = self.directory / "offsite-ran"
        result = self.run_job(
            "database-offsite", sys.executable, "-c",
            "from pathlib import Path; import sys; Path(sys.argv[1]).touch()", str(marker),
            extra_options=options,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())
        self.assertIn(b"offsite sync was not started", result.stderr)
        self.assertEqual(self.read("database-offsite")["lastOutcome"], "failure")

        archive = source / "directvideo_2026-03-01_110000.sql.gz.gpg"
        local = self.run_job(
            "database-local", sys.executable, "-c",
            "from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b'synthetic archive')", str(archive),
            extra_options=("--created-archive-dir", str(source)),
        )
        self.assertEqual(local.returncode, 0, local.stderr)
        self.assertEqual(self.read()["lastArchive"]["name"], archive.name)
        result = self.run_job("database-offsite", sys.executable, "-c", "pass", extra_options=options)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.read("database-offsite")["stableSourceArchive"])

        result = self.run_job(
            "database-offsite", sys.executable, "-c",
            "from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b'changed')", str(archive),
            extra_options=options,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read("database-offsite")["lastOutcome"], "failure")

    def test_offsite_wrapper_blocks_unconfirmed_changed_or_running_local_backups(self):
        source = self.directory / "archives"
        source.mkdir()
        archive = source / "directvideo_2026-03-01_110000.sql.gz.gpg"
        archive.write_bytes(b"partial archive")
        options = ("--require-archive-dir", str(source))
        result = self.run_job("database-offsite", sys.executable, "-c", "pass", extra_options=options)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"no confirmed recent local backup", result.stderr)

        local = self.run_job(
            "database-local", sys.executable, "-c",
            "from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b'complete archive')", str(archive),
            extra_options=("--created-archive-dir", str(source)),
        )
        self.assertEqual(local.returncode, 0, local.stderr)
        monitor_status.record(str(self.directory), "database-local", "start", str(uuid.uuid4()))
        result = self.run_job("database-offsite", sys.executable, "-c", "pass", extra_options=options)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"no confirmed recent local backup", result.stderr)

        local = self.run_job(
            "database-local", sys.executable, "-c",
            "from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b'new complete archive')", str(archive),
            extra_options=("--created-archive-dir", str(source)),
        )
        self.assertEqual(local.returncode, 0, local.stderr)
        archive.write_bytes(b"modified")
        result = self.run_job("database-offsite", sys.executable, "-c", "pass", extra_options=options)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"no confirmed recent local backup", result.stderr)

    def test_offsite_wrapper_blocks_if_start_receipt_cannot_be_recorded(self):
        source = self.directory / "archives"
        source.mkdir()
        archive = source / "directvideo_2026-03-01_110000.sql.gz.gpg"
        local = self.run_job(
            "database-local", sys.executable, "-c",
            "from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b'complete archive')", str(archive),
            extra_options=("--created-archive-dir", str(source)),
        )
        self.assertEqual(local.returncode, 0, local.stderr)

        offsite_state = self.directory / "database-offsite.json"
        offsite_state.write_text('{"version":1}')
        offsite_state.chmod(0o644)
        marker = self.directory / "offsite-ran"
        result = self.run_job(
            "database-offsite", sys.executable, "-c",
            "from pathlib import Path; import sys; Path(sys.argv[1]).touch()", str(marker),
            extra_options=("--require-archive-dir", str(source)),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())
        self.assertIn(b"could not record monitoring status", result.stderr)
        self.assertIn(b"offsite sync was not started", result.stderr)

    def test_local_wrapper_requires_a_new_archive_and_offsite_rejects_stale_receipts(self):
        source = self.directory / "archives"
        source.mkdir()
        archive = source / "directvideo_2026-03-01_110000.sql.gz.gpg"
        archive.write_bytes(b"old archive")
        options = ("--created-archive-dir", str(source))
        result = self.run_job("database-local", sys.executable, "-c", "pass", extra_options=options)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read()["lastOutcome"], "failure")

        result = self.run_job(
            "database-local", sys.executable, "-c",
            "from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b'new backup')", str(archive),
            extra_options=options,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.read()
        old = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=37)).isoformat(
            timespec="milliseconds"
        ).replace("+00:00", "Z")
        state["lastCompletedAt"] = old
        state["lastSuccessAt"] = old
        (self.directory / "database-local.json").write_text(json.dumps(state))
        result = self.run_job(
            "database-offsite", sys.executable, "-c", "pass",
            extra_options=("--require-archive-dir", str(source)),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"offsite sync was not started", result.stderr)

    def test_database_wrappers_serialize_backup_and_offsite_sync(self):
        source = self.directory / "archives"
        source.mkdir()
        archive = source / "directvideo_2026-03-01_110000.sql.gz.gpg"
        local_started = self.directory / "local-started"
        sync_started = self.directory / "sync-started"
        wrapper = str(Path(__file__).with_name("monitor_job.py"))
        local = subprocess.Popen(
            [
                sys.executable, wrapper, "--state-dir", str(self.directory), "--check", "database-local",
                "--created-archive-dir", str(source), "--", sys.executable, "-c",
                "from pathlib import Path; import sys, time; Path(sys.argv[1]).touch(); "
                "time.sleep(1); Path(sys.argv[2]).write_bytes(b'complete')",
                str(local_started), str(archive),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        def stop_if_running(process):
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)

        self.addCleanup(stop_if_running, local)
        deadline = time.monotonic() + 5
        while not local_started.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(local_started.exists())
        offsite = subprocess.Popen(
            [
                sys.executable, wrapper, "--state-dir", str(self.directory), "--check", "database-offsite",
                "--require-archive-dir", str(source), "--", sys.executable, "-c",
                "from pathlib import Path; import sys; Path(sys.argv[1]).touch()", str(sync_started),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.addCleanup(stop_if_running, offsite)
        time.sleep(0.1)
        self.assertFalse(sync_started.exists())
        _, local_error = local.communicate(timeout=10)
        _, offsite_error = offsite.communicate(timeout=10)
        self.assertEqual(local.returncode, 0, local_error)
        self.assertEqual(offsite.returncode, 0, offsite_error)
        self.assertTrue(sync_started.exists())


if __name__ == "__main__":
    unittest.main()

import contextlib
import fcntl
import io
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import backup_originals as backup


SOURCE_ID = "12345678-1234-4234-8234-123456789abc"
OTHER_ID = "87654321-4321-4321-8321-cba987654321"
OBJECT_ID = "abcdef01-2345-4567-89ab-cdef01234567"
LEGACY_ID = "12345678-abcd-4567-89ab-cdef01234567"
TEST_PASSWORD = "synthetic-config-password"
CONTENTS = b"synthetic-original-private-data-" * 12


class ConfigurationTests(unittest.TestCase):
    def test_crypt_requires_encrypted_content_and_names(self):
        config = {"type": "crypt", "remote": "/some/backup", "password": "synthetic"}
        self.assertEqual(backup.crypt_config({"local": config}, "local", "local"), "/some/backup")
        for field, value in (
            ("type", "local"),
            ("filename_encryption", "off"),
            ("filename_encryption", "obfuscate"),
            ("directory_name_encryption", "false"),
            ("no_data_encryption", "true"),
            ("pass_bad_blocks", "true"),
            ("password", ""),
            ("no_data_encryption", True),
        ):
            with self.subTest(field=field, value=value):
                with self.assertRaises(backup.BackupError):
                    backup.crypt_config({"local": {**config, field: value}}, "local", "local")

    def test_cloud_requires_native_b2_with_a_dedicated_prefix_and_checksums(self):
        options = SimpleNamespace(b2_remote="crypt")
        configs = {
            "crypt": {"type": "crypt", "remote": "b2:bucket/originals", "password": "synthetic"},
            "b2": {"type": "b2", "account": "synthetic", "key": "synthetic"},
        }
        destination = backup.cloud_destination(configs, options)
        self.assertEqual(destination.lifecycle_remote, "b2:bucket")
        self.assertEqual(destination.lifecycle_prefix, "originals/")
        for remote in (
            "b2:bucket", "b2:bucket/../originals", "b2:bucket/originals/",
            "b2:bucket/.hidden", "b2:bucket/unsafe:name", "/local",
        ):
            with self.subTest(remote=remote):
                changed = {**configs, "crypt": {**configs["crypt"], "remote": remote}}
                with self.assertRaises(backup.BackupError):
                    backup.cloud_destination(changed, options)
        for field, value in (
            ("type", "local"),
            ("key", ""),
            ("endpoint", "https://not-backblaze.invalid"),
            ("download_url", "https://not-backblaze.invalid"),
            ("disable_checksum", "true"),
        ):
            with self.subTest(field=field):
                changed = {**configs, "b2": {**configs["b2"], field: value}}
                with self.assertRaises(backup.BackupError):
                    backup.cloud_destination(changed, options)

    def test_lifecycle_rejects_expiration_only_when_the_prefix_can_overlap(self):
        destination = backup.Destination(
            "B2", "crypt", True, lifecycle_remote="b2:bucket", lifecycle_prefix="originals/encrypted/"
        )

        def verify(rules):
            runner = SimpleNamespace(run=lambda *_args: SimpleNamespace(stdout=json.dumps(rules).encode()))
            backup.verify_b2_lifecycle(runner, destination)

        verify([])
        verify([{"fileNamePrefix": "", "daysFromUploadingToHiding": None}])
        verify([{"fileNamePrefix": "different/", "daysFromUploadingToHiding": 3}])
        for prefix in ("", "originals/", "originals/encrypted/", "originals/encrypted/some-object"):
            with self.subTest(prefix=prefix):
                with self.assertRaisesRegex(backup.BackupError, "automatically hide"):
                    verify([{"fileNamePrefix": prefix, "daysFromUploadingToHiding": 3}])
        with self.assertRaisesRegex(backup.BackupError, "invalid lifecycle"):
            verify([{"fileNamePrefix": "", "daysFromUploadingToHiding": "3"}])
        with self.assertRaisesRegex(backup.BackupError, "invalid lifecycle"):
            verify([{"fileNamePrefix": ""}])

    def test_cryptcheck_requires_all_hashes_and_the_exact_match_count(self):
        def result(*messages):
            return SimpleNamespace(
                stderr=b"\n".join(json.dumps({"level": "notice", "msg": message}).encode() for message in messages)
            )

        backup.verify_cryptcheck_summary(result("0 differences found", "2 matching files"), 2, "B2")
        with self.assertRaisesRegex(backup.BackupError, "could not verify every checksum"):
            backup.verify_cryptcheck_summary(
                result("0 differences found", "1 hashes could not be checked", "2 matching files"), 2, "B2"
            )
        for messages in ((), ("1 matching files",), ("2 matching files", "2 matching files")):
            with self.subTest(messages=messages):
                with self.assertRaisesRegex(backup.BackupError, "did not verify every original"):
                    backup.verify_cryptcheck_summary(result(*messages), 2, "B2")
        with self.assertRaisesRegex(backup.BackupError, "unexpected notice"):
            backup.verify_cryptcheck_summary(
                result("0 differences found", "2 matching files", "some hashes were skipped"), 2, "B2"
            )
        with self.assertRaisesRegex(backup.BackupError, "invalid verification summary"):
            backup.verify_cryptcheck_summary(SimpleNamespace(stderr=b"not JSON"), 2, "B2")

    def test_same_filesystem_and_unmounted_volume_are_refused(self):
        with tempfile.TemporaryDirectory(prefix="dvu-backup-policy-") as directory:
            path = Path(directory)
            (path / "one").mkdir()
            (path / "two").mkdir()
            with self.assertRaisesRegex(backup.BackupError, "not a mounted filesystem"):
                backup.open_mount(str(path / "one"), "source")
            with contextlib.closing(backup.DirectoryGuard.open(str(path / "one"), "one")) as one:
                with contextlib.closing(backup.DirectoryGuard.open(str(path / "two"), "two")) as two:
                    with self.assertRaisesRegex(backup.BackupError, "same filesystem"):
                        backup.require_separate_devices(one, two)

    def test_backup_directory_must_be_inside_the_mount_and_not_a_symlink(self):
        with tempfile.TemporaryDirectory(prefix="dvu-backup-path-") as directory:
            path = Path(directory)
            mount = path / "mount"
            mount.mkdir()
            outside = path / "outside"
            outside.mkdir()
            (mount / "link").symlink_to(outside, target_is_directory=True)
            with contextlib.closing(backup.DirectoryGuard.open(str(mount), "mount")) as guard:
                with self.assertRaisesRegex(backup.BackupError, "outside"):
                    backup.directory_chain(guard, str(outside), "backup", require_child=True)
                with self.assertRaisesRegex(backup.BackupError, "dedicated directory"):
                    backup.directory_chain(guard, str(mount), "backup", require_child=True)
                with self.assertRaisesRegex(backup.BackupError, "symbolic link"):
                    backup.directory_chain(guard, str(mount / "link"), "backup", require_child=True)

    def test_printed_launch_agent_runs_hourly_without_embedding_a_password(self):
        options = SimpleNamespace(
            source_volume="/Volumes/source",
            source_root="/Volumes/source/original storage",
            source_id=SOURCE_ID,
            backup_volume="/Volumes/backup",
            backup_volume_id=OTHER_ID,
            local_remote="dvu-local",
            b2_remote="dvu-b2",
            rclone_config="/home/user/private.conf",
            password_helper="/home/user/password-helper",
            rclone="/usr/bin/rclone",
        )
        xml = backup.launchd_plist(options)
        plist = plistlib.loads(xml)
        self.assertEqual(plist["StartInterval"], 3600)
        self.assertIn(options.source_root, plist["ProgramArguments"])
        self.assertIn(options.password_helper, plist["ProgramArguments"])
        self.assertNotIn(TEST_PASSWORD.encode(), xml)

    @unittest.skipUnless(shutil.which("rclone"), "rclone is required to generate a LaunchAgent")
    def test_launch_agent_cli_produces_a_valid_plist(self):
        result = subprocess.run(
            [
                sys.executable, backup.__file__,
                "--source-volume", "/Volumes/source", "--source-root", "/Volumes/source/original storage",
                "--source-id", SOURCE_ID, "--backup-volume", "/Volumes/backup", "--backup-volume-id", OTHER_ID,
                "--local-remote", "localcrypt", "--b2-remote", "b2crypt",
                "--rclone-config", "/home/user/private.conf",
                "--password-helper", "/home/user/password helper", "--print-launchd",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        plist = plistlib.loads(result.stdout)
        self.assertEqual(plist["StartInterval"], 3600)
        self.assertNotIn("--print-launchd", plist["ProgramArguments"])
        self.assertIn("/home/user/password helper", plist["ProgramArguments"])


@unittest.skipUnless(shutil.which("rclone"), "rclone is required for encrypted backup integration tests")
class EncryptedBackupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dvu-original-backup-test-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.source_volume = self.base / "source volume"
        self.source = self.source_volume / "storage"
        self.backup_volume = self.base / "backup volume"
        self.local = self.backup_volume / "encrypted-originals"
        self.cloud = self.base / "fake B2 encrypted"
        for path in (self.source, self.local, self.cloud):
            path.mkdir(parents=True)
        (self.source / backup.STORAGE_MARKER).write_text(SOURCE_ID + "\n")
        (self.backup_volume / backup.VOLUME_MARKER).write_text(OTHER_ID + "\n")
        self.original = self.source / "originals" / "owner" / "asset" / "clip" / f"{SOURCE_ID}.{OBJECT_ID}"
        self.original.parent.mkdir(parents=True)
        self.original.write_bytes(CONTENTS)
        self.helper = self.base / "password helper"
        self.helper.write_text(f"#!/bin/sh\nprintf '%s\\n' '{TEST_PASSWORD}'\n")
        self.helper.chmod(0o700)
        self.config = self.base / "rclone.conf"
        self.rclone = shutil.which("rclone")
        self.config_command(
            "config", "create", "localcrypt", "crypt",
            "remote", str(self.local), "password", "synthetic-local-crypt",
            "--obscure", "--non-interactive",
        )
        self.config_command(
            "config", "create", "cloudcrypt", "crypt",
            "remote", str(self.cloud), "password", "synthetic-cloud-crypt",
            "--obscure", "--non-interactive",
        )
        self.config_command("config", "encryption", "set", "--password-command", f'"{self.helper}"')
        self.config.chmod(0o600)
        self.assertNotIn(TEST_PASSWORD.encode(), self.config.read_bytes())
        self.assertNotIn(b"synthetic-cloud-crypt", self.config.read_bytes())
        self.arguments = [
            "--source-volume", str(self.source_volume),
            "--source-root", str(self.source),
            "--source-id", SOURCE_ID,
            "--backup-volume", str(self.backup_volume),
            "--backup-volume-id", OTHER_ID,
            "--local-remote", "localcrypt",
            "--b2-remote", "cloudcrypt",
            "--rclone-config", str(self.config),
            "--password-helper", str(self.helper),
            "--rclone", self.rclone,
        ]
        self.environment = mock.patch.dict(os.environ, {"HOME": str(self.base)})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.mounts = mock.patch.object(backup.os.path, "ismount", return_value=True)
        self.mounts.start()
        self.addCleanup(self.mounts.stop)
        self.devices = mock.patch.object(backup, "require_separate_devices")
        self.devices.start()
        self.addCleanup(self.devices.stop)
        self.cloud_check = mock.patch.object(
            backup, "cloud_destination", return_value=backup.Destination("B2", "cloudcrypt", False)
        )
        self.cloud_check.start()
        self.addCleanup(self.cloud_check.stop)

    def config_command(self, *arguments):
        result = subprocess.run(
            [self.rclone, "--config", str(self.config), "--ask-password=false", *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return result

    def crypt_command(self, *arguments):
        environment = {key: value for key, value in os.environ.items() if not key.upper().startswith("RCLONE_")}
        environment["RCLONE_CONFIG_PASS"] = TEST_PASSWORD
        result = subprocess.run(
            [self.rclone, "--config", str(self.config), "--ask-password=false", *arguments],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return result

    def run_backup(self, *arguments):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = backup.main([*self.arguments, *arguments])
        self.assertNotIn(TEST_PASSWORD, output.getvalue())
        self.assertNotIn("synthetic-local-crypt", output.getvalue())
        return status, output.getvalue()

    def decrypted_original(self, remote):
        path = self.original.relative_to(self.source).as_posix()
        return self.crypt_command("cat", f"{remote}:{path}").stdout

    def test_real_encryption_excludes_uploads_and_retains_deleted_originals(self):
        staged = self.source / ".uploads" / "parts"
        staged.mkdir(parents=True)
        (staged / "part").write_bytes(b"unfinished-upload-must-not-be-copied")
        partial = self.original.parent / f".partial-123-{OBJECT_ID}"
        partial.write_bytes(b"unfinished-assembly-must-not-be-copied")
        legacy = self.original.parent / LEGACY_ID
        legacy.write_bytes(b"legacy-original")
        status, output = self.run_backup()
        self.assertEqual(status, 0, output)
        self.assertIn("2 published originals", output)
        self.assertIn("1 legacy originals", output)
        for remote, raw in (("localcrypt", self.local), ("cloudcrypt", self.cloud)):
            self.assertEqual(self.decrypted_original(remote), CONTENTS)
            names = self.crypt_command("lsf", f"{remote}:", "--recursive").stdout.decode()
            self.assertNotIn(".uploads", names)
            self.assertNotIn(".partial-", names)
            raw_files = [path for path in raw.rglob("*") if path.is_file()]
            self.assertEqual(len(raw_files), 3)
            for path in raw_files:
                data = path.read_bytes()
                self.assertNotIn(CONTENTS, data)
                self.assertNotIn(b"synthetic-original-private-data", data)
                self.assertNotIn(b"unfinished", data)
                self.assertNotIn("owner", path.as_posix())
        self.original.unlink()
        legacy.unlink()
        status, output = self.run_backup()
        self.assertEqual(status, 0, output)
        self.assertIn("0 published originals", output)
        self.assertEqual(self.decrypted_original("localcrypt"), CONTENTS)
        self.assertEqual(self.decrypted_original("cloudcrypt"), CONTENTS)
        for remote in ("localcrypt", "cloudcrypt"):
            restore = self.base / f"restore-{remote}"
            restore.mkdir()
            result = subprocess.run(
                [
                    self.rclone, "--config", str(self.config), "--ask-password=false",
                    "--password-command", f'"{self.helper}"', "--crypt-strict-names",
                    "--crypt-filename-encryption", "standard", "--crypt-directory-name-encryption=true",
                    "--crypt-no-data-encryption=false", "--crypt-pass-bad-blocks=false",
                    "copy", f"{remote}:", str(restore), "--immutable",
                ],
                env={"HOME": str(self.base), "PATH": "/usr/bin:/bin"},
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            self.assertEqual((restore / backup.STORAGE_MARKER).read_text().strip(), SOURCE_ID)
            self.assertEqual((restore / self.original.relative_to(self.source)).read_bytes(), CONTENTS)
            self.assertEqual((restore / legacy.relative_to(self.source)).read_bytes(), b"legacy-original")
            self.assertFalse((restore / ".uploads").exists())

    def test_source_change_with_same_size_and_mtime_never_overwrites_a_backup(self):
        status, output = self.run_backup()
        self.assertEqual(status, 0, output)
        before = self.original.stat()
        self.original.write_bytes(b"x" * len(CONTENTS))
        os.utime(self.original, ns=(before.st_atime_ns, before.st_mtime_ns))
        status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("cryptcheck", output)
        self.assertEqual(self.decrypted_original("localcrypt"), CONTENTS)
        self.assertEqual(self.decrypted_original("cloudcrypt"), CONTENTS)

    def test_explicit_removal_is_preserved_when_the_source_is_gone(self):
        status, output = self.run_backup()
        self.assertEqual(status, 0, output)
        key = self.original.relative_to(self.source).as_posix()
        self.original.unlink()
        self.crypt_command("deletefile", f"localcrypt:{key}", "--dry-run")
        self.assertEqual(self.decrypted_original("localcrypt"), CONTENTS)
        self.crypt_command("deletefile", f"localcrypt:{key}")
        status, output = self.run_backup()
        self.assertEqual(status, 0, output)
        listed = self.crypt_command("lsf", "localcrypt:", "--recursive", "--files-only").stdout.decode()
        self.assertNotIn(key, listed)
        self.assertEqual(self.decrypted_original("cloudcrypt"), CONTENTS)

    def test_corrupted_encrypted_file_fails_verification_without_replacement(self):
        status, output = self.run_backup()
        self.assertEqual(status, 0, output)
        encrypted = max((path for path in self.local.rglob("*") if path.is_file()), key=lambda path: path.stat().st_size)
        before = encrypted.stat()
        data = bytearray(encrypted.read_bytes())
        data[-1] ^= 1
        encrypted.write_bytes(data)
        os.utime(encrypted, ns=(before.st_atime_ns, before.st_mtime_ns))
        status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("local backup", output)
        self.assertIn("B2 backup verified", output)
        self.assertEqual(encrypted.read_bytes(), data)

    def test_local_volume_failure_still_attempts_b2(self):
        (self.backup_volume / backup.VOLUME_MARKER).write_text(SOURCE_ID + "\n")
        status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("backup volume marker does not match", output)
        self.assertIn("B2 backup verified", output)
        self.assertEqual(self.decrypted_original("cloudcrypt"), CONTENTS)
        self.assertEqual(list(self.local.iterdir()), [])

    def test_local_crypt_path_cannot_contain_parent_traversal(self):
        unsafe = str(self.local / ".." / "encrypted-originals")
        self.crypt_command("config", "update", "localcrypt", "remote", unsafe, "--non-interactive")
        status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("without '.' or '..' components", output)
        self.assertIn("B2 backup verified", output)
        self.assertEqual(list(self.local.iterdir()), [])

    def test_nonempty_destination_without_marker_is_not_initialized(self):
        stray = self.base / "stray"
        stray.write_bytes(b"existing destination")
        self.crypt_command("copyto", str(stray), "cloudcrypt:stray")
        status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("nonempty but has no storage marker", output)
        self.assertEqual(self.crypt_command("cat", "cloudcrypt:stray").stdout, b"existing destination")
        listing = self.crypt_command("lsf", "cloudcrypt:").stdout.decode()
        self.assertNotIn(backup.STORAGE_MARKER, listing)
        self.assertIn("local backup verified", output)

    def test_undecryptable_destination_entries_are_not_ignored(self):
        unexpected = self.cloud / "plaintext-unexpected"
        unexpected.write_bytes(b"existing unencrypted object")
        status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("B2 encrypted destination listing failed", output)
        self.assertIn("local backup verified", output)
        self.assertEqual(unexpected.read_bytes(), b"existing unencrypted object")

    def test_local_backup_tree_rejects_symlinks_and_special_files(self):
        unsafe = self.local / "unsafe"
        unsafe.symlink_to(self.base)
        status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("local backup tree contains a symbolic link or unsupported file", output)
        self.assertIn("B2 backup verified", output)
        unsafe.unlink()
        os.mkfifo(unsafe)
        status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("local backup tree contains a symbolic link or unsupported file", output)
        self.assertIn("B2 backup verified", output)

    def test_wrong_destination_marker_does_not_copy_originals(self):
        wrong = self.base / "wrong-marker"
        wrong.write_text(OTHER_ID + "\n")
        self.crypt_command("copyto", str(wrong), f"cloudcrypt:{backup.STORAGE_MARKER}")
        status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("marker does not match the source identity", output)
        listing = self.crypt_command("lsf", "cloudcrypt:", "--recursive").stdout.decode()
        self.assertNotIn("originals/", listing)
        self.assertIn("local backup verified", output)

    def test_changed_destination_marker_fails_the_final_verification(self):
        wrong = self.base / "wrong-marker"
        wrong.write_text(OTHER_ID + "\n")
        original_run = backup.Rclone.run

        def change_during_check(runner, action, arguments, allowed_codes=()):
            result = original_run(runner, action, arguments, allowed_codes)
            if action == "local cryptcheck":
                self.crypt_command("copyto", str(wrong), f"localcrypt:{backup.STORAGE_MARKER}", "--ignore-times")
            return result

        with mock.patch.object(backup.Rclone, "run", change_during_check):
            status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("local backup: local marker does not match", output)
        self.assertIn("B2 backup verified", output)
        self.assertNotIn("local backup verified", output)

    def test_expiring_b2_lifecycle_does_not_block_independent_local_backup(self):
        destination = backup.Destination(
            "B2", "cloudcrypt", False,
            lifecycle_remote="b2:bucket", lifecycle_prefix="originals/",
        )
        original_run = backup.Rclone.run

        def lifecycle_response(runner, action, arguments, allowed_codes=()):
            if action == "B2 lifecycle inspection":
                rules = [{"fileNamePrefix": "", "daysFromUploadingToHiding": 30}]
                return SimpleNamespace(stdout=json.dumps(rules).encode())
            return original_run(runner, action, arguments, allowed_codes)

        with mock.patch.object(backup, "cloud_destination", return_value=destination):
            with mock.patch.object(backup.Rclone, "run", lifecycle_response):
                status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("local backup verified", output)
        self.assertIn("automatically hide retained originals", output)
        self.assertEqual(list(self.cloud.iterdir()), [])

    def test_missing_and_invalid_source_or_symlink_fail_before_writing(self):
        (self.source / backup.STORAGE_MARKER).write_text(OTHER_ID + "\n")
        status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("source marker does not match", output)
        self.assertEqual(list(self.local.iterdir()), [])
        (self.source / backup.STORAGE_MARKER).write_text(SOURCE_ID + "\n")
        self.original.unlink()
        self.original.symlink_to(self.helper)
        status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("invalid file or symbolic link", output)
        self.assertEqual(list(self.local.iterdir()), [])

    def test_source_changes_during_copy_do_not_report_success(self):
        original_run = backup.Rclone.run

        def change_during_copy(runner, action, arguments, allowed_codes=()):
            result = original_run(runner, action, arguments, allowed_codes)
            if action == "local original copy":
                self.original.write_bytes(b"changed while copying")
            return result

        with mock.patch.object(backup.Rclone, "run", change_during_copy):
            status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("original changed during backup", output)
        self.assertNotIn("backup verified", output)

    def test_environment_overrides_cannot_disable_encryption_or_redirect_remote(self):
        with mock.patch.dict(os.environ, {
            "RCLONE_CRYPT_NO_DATA_ENCRYPTION": "true",
            "RCLONE_CONFIG_LOCALCRYPT_REMOTE": str(self.base / "wrong-destination"),
            "RCLONE_CONFIG_PASS": "incorrect-password",
        }):
            status, output = self.run_backup()
        self.assertEqual(status, 0, output)
        self.assertFalse((self.base / "wrong-destination").exists())
        self.assertEqual(self.decrypted_original("localcrypt"), CONTENTS)
        for path in self.local.rglob("*"):
            if path.is_file():
                self.assertNotIn(CONTENTS, path.read_bytes())

    def test_explicitly_unencrypted_crypt_configuration_is_refused(self):
        self.crypt_command("config", "update", "localcrypt", "no_data_encryption", "true", "--non-interactive")
        status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("must encrypt file data, filenames and directories", output)
        self.assertIn("B2 backup verified", output)
        self.assertEqual(list(self.local.iterdir()), [])

    def test_plaintext_config_is_rejected(self):
        plaintext = self.base / "plaintext.conf"
        plaintext.write_text("[localcrypt]\ntype = crypt\nremote = /unused\npassword = synthetic\n")
        plaintext.chmod(0o600)
        index = self.arguments.index("--rclone-config") + 1
        self.arguments[index] = str(plaintext)
        status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("encrypted rclone config verification failed", output)
        self.assertEqual(list(self.local.iterdir()), [])

    def test_unprotected_or_linked_config_is_rejected(self):
        self.config.chmod(0o644)
        status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("private, user-owned regular file", output)
        self.config.chmod(0o600)
        link = self.base / "linked-config"
        link.symlink_to(self.config)
        self.arguments[self.arguments.index("--rclone-config") + 1] = str(link)
        status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("rclone config cannot be opened", output)
        self.assertEqual(list(self.local.iterdir()), [])

    def test_incorrect_password_fails_without_exposing_it(self):
        self.helper.write_text("#!/bin/sh\nprintf '%s\\n' 'synthetic-wrong-password'\n")
        status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("encrypted rclone config verification failed", output)
        self.assertNotIn("synthetic-wrong-password", output)
        self.assertEqual(list(self.local.iterdir()), [])

    def test_overlapping_run_is_rejected(self):
        state = self.base / ".dvu-original-backup"
        state.mkdir(mode=0o700)
        fd = os.open(state / "backup.lock", os.O_CREAT | os.O_RDWR, 0o600)
        self.addCleanup(os.close, fd)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        status, output = self.run_backup()
        self.assertEqual(status, 1, output)
        self.assertIn("another originals backup is already running", output)
        self.assertEqual(list(self.local.iterdir()), [])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Back up published local originals to two independently encrypted destinations."""

import argparse
import contextlib
import datetime
import fcntl
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid
from dataclasses import dataclass
from typing import Optional

import monitor_status


UUID = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
    re.IGNORECASE,
)
IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
REMOTE_NAME = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_-]*$")
B2_PATH_SEGMENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")
PARTIAL = re.compile(
    r"^\.partial-[0-9]+-[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-"
    r"[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
    re.IGNORECASE,
)
STORAGE_MARKER = ".dvu-storage-id"
VOLUME_MARKER = ".dvu-original-backup-volume-id"
LAUNCHD_LABEL = "com.msfixer.original-backup"
CONFIG_LIMIT = 1024 * 1024


class BackupError(Exception):
    pass


def log(message):
    now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    print(f"{now} {message}", flush=True)


def absolute_path(value, label):
    if not os.path.isabs(value):
        raise BackupError(f"{label} must be an absolute path")
    return os.path.normpath(value)


def valid_uuid(value, label):
    if not UUID.fullmatch(value):
        raise BackupError(f"{label} must be a UUID")
    return value.lower()


def valid_remote(value, label):
    if not REMOTE_NAME.fullmatch(value):
        raise BackupError(f"{label} must be a named rclone remote without ':' or a path")
    return value


def file_identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def directory_identity(info):
    return (info.st_dev, info.st_ino)


def directory_info(path, label):
    try:
        info = os.lstat(path)
    except OSError as error:
        raise BackupError(f"{label} is unavailable (errno {error.errno})") from error
    if not stat.S_ISDIR(info.st_mode):
        raise BackupError(f"{label} is not a directory or is a symbolic link")
    return info


@dataclass
class DirectoryGuard:
    path: str
    label: str
    identity: tuple
    fd: int

    @classmethod
    def open(cls, path, label):
        path = absolute_path(path, label)
        info = directory_info(path, label)
        try:
            fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        except OSError as error:
            raise BackupError(f"{label} cannot be opened (errno {error.errno})") from error
        guard = cls(path, label, directory_identity(info), fd)
        try:
            guard.verify()
        except BackupError:
            os.close(fd)
            raise
        return guard

    def verify(self):
        current = directory_info(self.path, self.label)
        try:
            opened = os.fstat(self.fd)
        except OSError as error:
            raise BackupError(f"{self.label} became unavailable (errno {error.errno})") from error
        if directory_identity(current) != self.identity or directory_identity(opened) != self.identity:
            raise BackupError(f"{self.label} changed during backup")

    def close(self):
        os.close(self.fd)


def open_mount(path, label):
    guard = DirectoryGuard.open(path, label)
    if not os.path.ismount(guard.path):
        guard.close()
        raise BackupError(f"{label} is not a mounted filesystem")
    return guard


def directory_chain(mount, target, label, require_child=False):
    target = absolute_path(target, label)
    try:
        relative = os.path.relpath(target, mount.path)
    except ValueError as error:
        raise BackupError(f"{label} is outside its configured volume") from error
    if relative == os.pardir or relative.startswith(os.pardir + os.sep) or os.path.isabs(relative):
        raise BackupError(f"{label} is outside its configured volume")
    if require_child and relative == ".":
        raise BackupError(f"{label} must be a dedicated directory below the volume root")

    entries = []
    current = mount.path
    for part in (() if relative == "." else relative.split(os.sep)):
        current = os.path.join(current, part)
        info = directory_info(current, label)
        if info.st_dev != mount.identity[0]:
            raise BackupError(f"{label} contains another mounted filesystem")
        entries.append((current, directory_identity(info)))
    return entries


def verify_directories(entries, label):
    for path, expected in entries:
        info = directory_info(path, label)
        if directory_identity(info) != expected:
            raise BackupError(f"{label} changed during backup")


def verify_backup_tree(root, expected_device):
    pending = [root]
    while pending:
        directory = pending.pop()
        before = directory_info(directory, "local backup tree")
        if before.st_dev != expected_device:
            raise BackupError("local backup tree contains another mounted filesystem")
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    info = entry.stat(follow_symlinks=False)
                    if info.st_dev != expected_device:
                        raise BackupError("local backup tree contains another mounted filesystem")
                    if stat.S_ISDIR(info.st_mode):
                        pending.append(entry.path)
                    elif not stat.S_ISREG(info.st_mode):
                        raise BackupError("local backup tree contains a symbolic link or unsupported file")
        except OSError as error:
            raise BackupError(f"local backup tree cannot be inspected (errno {error.errno})") from error
        after = directory_info(directory, "local backup tree")
        if directory_identity(before) != directory_identity(after):
            raise BackupError("local backup tree changed during inspection")


def read_marker(path, expected_device, label):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as error:
        raise BackupError(f"{label} cannot be opened (errno {error.errno})") from error
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_dev != expected_device or info.st_size > 64:
            raise BackupError(f"{label} is not a valid regular marker file")
        value = os.read(fd, 65)
        if len(value) != info.st_size:
            raise BackupError(f"{label} changed while being read")
        try:
            identity = valid_uuid(value.decode("ascii").strip(), label)
        except UnicodeDecodeError as error:
            raise BackupError(f"{label} is not a valid UUID") from error
        if file_identity(os.fstat(fd)) != file_identity(info):
            raise BackupError(f"{label} changed while being read")
        return identity, file_identity(info)
    except OSError as error:
        raise BackupError(f"{label} cannot be read (errno {error.errno})") from error
    finally:
        os.close(fd)


def require_separate_devices(source_mount, backup_mount):
    if source_mount.identity[0] == backup_mount.identity[0]:
        raise BackupError("source and backup volumes are on the same filesystem")


@dataclass
class SourceSnapshot:
    root: str
    identity: str
    marker_identity: tuple
    mount: DirectoryGuard
    directories: list
    files: dict
    legacy_count: int

    def verify(self):
        self.mount.verify()
        verify_directories(self.directories, "source directory")
        marker, marker_identity = read_marker(
            os.path.join(self.root, STORAGE_MARKER), self.mount.identity[0], "source marker"
        )
        if marker != self.identity or marker_identity != self.marker_identity:
            raise BackupError("source marker changed during backup")
        for relative, expected in self.files.items():
            path = os.path.join(self.root, relative)
            try:
                info = os.lstat(path)
            except OSError as error:
                raise BackupError(f"a published original changed or disappeared (errno {error.errno})") from error
            if not stat.S_ISREG(info.st_mode) or file_identity(info) != expected:
                raise BackupError("a published original changed during backup")


def inventory_source(root, identity, mount):
    root = absolute_path(root, "source root")
    directories = directory_chain(mount, root, "source root")
    marker, marker_identity = read_marker(
        os.path.join(root, STORAGE_MARKER), mount.identity[0], "source marker"
    )
    if marker != identity:
        raise BackupError("source marker does not match the configured source identity")

    files = {}
    legacy_count = 0
    originals = os.path.join(root, "originals")
    try:
        info = os.lstat(originals)
    except FileNotFoundError:
        info = None
    except OSError as error:
        raise BackupError(f"originals directory is unavailable (errno {error.errno})") from error

    def visit(directory, depth):
        nonlocal legacy_count
        try:
            with os.scandir(directory) as iterator:
                entries = sorted(iterator, key=lambda entry: entry.name)
        except OSError as error:
            raise BackupError(f"originals inventory failed (errno {error.errno})") from error

        for entry in entries:
            temporary = depth == 3 and PARTIAL.fullmatch(entry.name)
            try:
                current = entry.stat(follow_symlinks=False)
            except FileNotFoundError as error:
                if temporary:
                    continue
                raise BackupError("a published source path disappeared during inventory") from error
            except OSError as error:
                raise BackupError(f"an original cannot be inspected (errno {error.errno})") from error
            if current.st_dev != mount.identity[0]:
                raise BackupError("originals contain another mounted filesystem")
            if temporary:
                if not stat.S_ISREG(current.st_mode):
                    raise BackupError("an assembly temporary is not a regular file")
                continue
            if depth < 3:
                if not IDENTIFIER.fullmatch(entry.name) or not stat.S_ISDIR(current.st_mode):
                    raise BackupError("originals contain an invalid directory or symbolic link")
                directories.append((entry.path, directory_identity(current)))
                visit(entry.path, depth + 1)
                continue
            parts = entry.name.split(".")
            if (
                not stat.S_ISREG(current.st_mode)
                or len(parts) not in (1, 2)
                or any(not UUID.fullmatch(part) for part in parts)
            ):
                raise BackupError("originals contain an invalid file or symbolic link")
            if len(parts) == 2 and parts[0].lower() != identity:
                raise BackupError("an original belongs to a different storage identity")
            if len(parts) == 1:
                legacy_count += 1
            files[os.path.relpath(entry.path, root)] = file_identity(current)

    if info is not None:
        if not stat.S_ISDIR(info.st_mode) or info.st_dev != mount.identity[0]:
            raise BackupError("originals directory is invalid or on another filesystem")
        directories.append((originals, directory_identity(info)))
        visit(originals, 0)
    snapshot = SourceSnapshot(root, identity, marker_identity, mount, directories, files, legacy_count)
    snapshot.verify()
    return snapshot


@contextlib.contextmanager
def backup_lock():
    state = os.path.join(os.path.expanduser("~"), ".dvu-original-backup")
    try:
        os.makedirs(state, mode=0o700, exist_ok=True)
        info = os.lstat(state)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise BackupError("backup state directory must be private and owned by the current user")
        fd = os.open(os.path.join(state, "backup.lock"), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    except OSError as error:
        raise BackupError(f"backup lock is unavailable (errno {error.errno})") from error
    try:
        lock_info = os.fstat(fd)
        if not stat.S_ISREG(lock_info.st_mode) or lock_info.st_uid != os.getuid():
            raise BackupError("backup lock is not a regular file owned by the current user")
        os.fchmod(fd, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise BackupError("another originals backup is already running") from error
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def copy_private_config(source, destination):
    source = absolute_path(source, "rclone config")
    repository = os.path.realpath(os.path.join(os.path.dirname(__file__), os.pardir))
    if os.path.commonpath((repository, os.path.realpath(source))) == repository:
        raise BackupError("the rclone config must be outside the repository")
    try:
        fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as error:
        raise BackupError(f"rclone config cannot be opened (errno {error.errno})") from error
    try:
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_mode & 0o077
            or info.st_size > CONFIG_LIMIT
        ):
            raise BackupError("rclone config must be a private, user-owned regular file under 1 MiB")
        with os.fdopen(os.dup(fd), "rb") as config:
            contents = config.read(CONFIG_LIMIT + 1)
        if len(contents) != info.st_size or file_identity(os.fstat(fd)) != file_identity(info):
            raise BackupError("rclone config changed while being read")
    finally:
        os.close(fd)
    with open(destination, "xb") as snapshot:
        os.chmod(destination, 0o600)
        snapshot.write(contents)


def rclone_environment(password_helper):
    password_helper = absolute_path(password_helper, "password helper")
    try:
        info = os.lstat(password_helper)
    except OSError as error:
        raise BackupError(f"password helper is unavailable (errno {error.errno})") from error
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_mode & 0o022
        or not os.access(password_helper, os.X_OK)
    ):
        raise BackupError("password helper must be an executable, user-owned regular file not writable by others")
    env = {key: value for key, value in os.environ.items() if not key.upper().startswith("RCLONE_")}
    try:
        result = subprocess.run(
            [password_helper], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise BackupError("password helper could not run") from error
    if result.returncode != 0:
        raise BackupError(f"password helper failed (exit {result.returncode})")
    try:
        password = result.stdout.decode("utf-8").rstrip("\r\n")
    except UnicodeDecodeError as error:
        raise BackupError("password helper returned invalid UTF-8") from error
    if not password or len(password) > 4096 or "\n" in password or "\r" in password:
        raise BackupError("password helper must return one nonempty password line")
    env["RCLONE_CONFIG_PASS"] = password
    return env


class Rclone:
    def __init__(self, binary, config, env):
        self.binary = binary
        self.config = config
        self.env = env

    def run(self, action, arguments, allowed_codes=()):
        command = [
            self.binary,
            "--config", self.config,
            "--ask-password=false",
            "--log-level", "ERROR",
            "--crypt-strict-names",
            "--crypt-no-data-encryption=false",
            "--crypt-pass-bad-blocks=false",
            "--crypt-filename-encryption", "standard",
            "--crypt-directory-name-encryption=true",
        ] + list(arguments)
        try:
            result = subprocess.run(command, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        except OSError as error:
            raise BackupError(f"{action} could not start rclone (errno {error.errno})") from error
        if result.returncode != 0 and result.returncode not in allowed_codes:
            raise BackupError(f"{action} failed (rclone exit {result.returncode}); see the runbook")
        return result

    def configs(self):
        self.run("encrypted rclone config verification", ["config", "encryption", "check"])
        result = self.run("rclone config inspection", ["config", "dump"])
        try:
            configs = json.loads(result.stdout)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise BackupError("rclone returned an invalid config") from error
        if not isinstance(configs, dict):
            raise BackupError("rclone returned an invalid config")
        return configs


def crypt_config(configs, name, label):
    config = configs.get(name)
    if not isinstance(config, dict) or config.get("type") != "crypt":
        raise BackupError(f"{label} must be a configured crypt remote")
    settings = {
        "filename_encryption": "standard",
        "directory_name_encryption": "true",
        "no_data_encryption": "false",
        "pass_bad_blocks": "false",
    }
    if (
        any(not isinstance(config.get(key, expected), str)
            or config.get(key, expected).strip().lower() != expected
            for key, expected in settings.items())
        or not config.get("password")
    ):
        raise BackupError(f"{label} must encrypt file data, filenames and directories")
    remote = config.get("remote")
    if not isinstance(remote, str) or not remote:
        raise BackupError(f"{label} has no underlying destination")
    return remote


@dataclass
class Destination:
    label: str
    remote: str
    missing_directory_ok: bool
    mount: Optional[DirectoryGuard] = None
    directories: Optional[list] = None
    marker_path: Optional[str] = None
    marker_identity: Optional[tuple] = None
    volume_identity: Optional[str] = None
    lifecycle_remote: Optional[str] = None
    lifecycle_prefix: Optional[str] = None
    tree_root: Optional[str] = None

    def verify(self):
        if self.mount is None:
            return
        if (
            self.directories is None
            or self.marker_path is None
            or self.marker_identity is None
            or self.volume_identity is None
            or self.tree_root is None
        ):
            raise BackupError("local backup destination is not fully configured")
        self.mount.verify()
        verify_directories(self.directories, "backup directory")
        verify_backup_tree(self.tree_root, self.mount.identity[0])
        identity, marker_identity = read_marker(
            self.marker_path, self.mount.identity[0], "backup volume marker"
        )
        if identity != self.volume_identity or marker_identity != self.marker_identity:
            raise BackupError("backup volume marker changed during backup")


@contextlib.contextmanager
def local_destination(configs, options, source_mount):
    underlying = crypt_config(configs, options.local_remote, "local backup")
    if (
        not os.path.isabs(underlying)
        or underlying.startswith("//")
        or any(part in (".", "..") for part in underlying.split(os.sep))
    ):
        raise BackupError("local crypt directory must be an absolute path without '.' or '..' components")
    underlying = os.path.normpath(underlying)
    backup_mount = open_mount(options.backup_volume, "backup volume")
    try:
        require_separate_devices(source_mount, backup_mount)
        marker_path = os.path.join(backup_mount.path, VOLUME_MARKER)
        marker, marker_identity = read_marker(marker_path, backup_mount.identity[0], "backup volume marker")
        if marker != options.backup_volume_id:
            raise BackupError("backup volume marker does not match the configured identity")
        directories = directory_chain(backup_mount, underlying, "local crypt directory", require_child=True)
        destination = Destination(
            "local", options.local_remote, False,
            mount=backup_mount,
            directories=directories,
            marker_path=marker_path,
            marker_identity=marker_identity,
            volume_identity=marker,
            tree_root=underlying,
        )
        destination.verify()
        yield destination
    finally:
        backup_mount.close()


def cloud_destination(configs, options):
    underlying = crypt_config(configs, options.b2_remote, "B2 backup")
    name, separator, path = underlying.partition(":")
    if not separator or not REMOTE_NAME.fullmatch(name):
        raise BackupError("B2 crypt must wrap a named B2 remote")
    segments = path.split("/")
    if len(segments) < 2 or any(not B2_PATH_SEGMENT.fullmatch(part) for part in segments):
        raise BackupError("B2 crypt must use a dedicated ASCII bucket prefix")
    b2 = configs.get(name)
    if not isinstance(b2, dict) or b2.get("type") != "b2":
        raise BackupError("B2 crypt must wrap a native B2 remote")
    if (
        not b2.get("account")
        or not b2.get("key")
        or b2.get("endpoint")
        or b2.get("download_url")
        or b2.get("test_mode")
        or not isinstance(b2.get("disable_checksum", "false"), str)
        or b2.get("disable_checksum", "false").strip().lower() != "false"
    ):
        raise BackupError("B2 remote must use its standard endpoint and enabled checksums")
    return Destination(
        "B2",
        options.b2_remote,
        True,
        lifecycle_remote=f"{name}:{segments[0]}",
        lifecycle_prefix="/".join(segments[1:]) + "/",
    )


def verify_b2_lifecycle(rclone, destination):
    if destination.lifecycle_remote is None or destination.lifecycle_prefix is None:
        raise BackupError("B2 lifecycle destination is not fully configured")
    result = rclone.run("B2 lifecycle inspection", ["backend", "lifecycle", destination.lifecycle_remote])
    try:
        rules = json.loads(result.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise BackupError("B2 returned invalid lifecycle rules") from error
    if not isinstance(rules, list):
        raise BackupError("B2 returned invalid lifecycle rules")
    for rule in rules:
        if (
            not isinstance(rule, dict)
            or not isinstance(rule.get("fileNamePrefix"), str)
            or "daysFromUploadingToHiding" not in rule
        ):
            raise BackupError("B2 returned invalid lifecycle rules")
        days = rule.get("daysFromUploadingToHiding")
        if days is not None and (isinstance(days, bool) or not isinstance(days, int) or days < 0):
            raise BackupError("B2 returned invalid lifecycle rules")
        prefix = rule["fileNamePrefix"]
        overlaps = destination.lifecycle_prefix.startswith(prefix) or prefix.startswith(destination.lifecycle_prefix)
        if overlaps and days:
            raise BackupError("B2 lifecycle rules would automatically hide retained originals")


def verify_destination_marker(rclone, destination, snapshot):
    result = rclone.run(
        f"{destination.label} marker verification",
        ["cat", f"{destination.remote}:{STORAGE_MARKER}", "--count", "65"],
    )
    try:
        marker = result.stdout.decode("ascii").strip().lower()
    except UnicodeDecodeError as error:
        raise BackupError(f"{destination.label} marker is invalid") from error
    if len(result.stdout) > 64 or marker != snapshot.identity:
        raise BackupError(f"{destination.label} marker does not match the source identity")


def initialize_destination(rclone, destination, snapshot):
    result = rclone.run(
        f"{destination.label} encrypted destination listing",
        ["lsf", f"{destination.remote}:", "--max-depth", "1"],
        allowed_codes=(3,) if destination.missing_directory_ok else (),
    )
    try:
        names = result.stdout.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise BackupError(f"{destination.label} destination returned invalid names") from error
    if STORAGE_MARKER not in names:
        if names:
            raise BackupError(f"{destination.label} destination is nonempty but has no storage marker")
        destination.verify()
        snapshot.verify()
        rclone.run(
            f"{destination.label} marker creation",
            ["copyto", os.path.join(snapshot.root, STORAGE_MARKER),
             f"{destination.remote}:{STORAGE_MARKER}", "--immutable", "--no-update-modtime"],
        )
    verify_destination_marker(rclone, destination, snapshot)


def verify_cryptcheck_summary(result, expected_count, label):
    matches = []
    differences = []
    for line in result.stderr.splitlines():
        try:
            entry = json.loads(line)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise BackupError(f"{label} cryptcheck returned an invalid verification summary") from error
        if (
            not isinstance(entry, dict)
            or entry.get("level") != "notice"
            or not isinstance(entry.get("msg"), str)
        ):
            raise BackupError(f"{label} cryptcheck returned an invalid verification summary")
        message = entry["msg"]
        if re.fullmatch(r"[0-9]+ hashes could not be checked", message):
            raise BackupError(f"{label} cryptcheck could not verify every checksum")
        match = re.fullmatch(r"([0-9]+) matching files", message)
        if match:
            matches.append(int(match.group(1)))
            continue
        difference = re.fullmatch(r"([0-9]+) differences found", message)
        if difference:
            differences.append(int(difference.group(1)))
            continue
        raise BackupError(f"{label} cryptcheck reported an unexpected notice; see the runbook")
    if matches != [expected_count] or differences != [0]:
        raise BackupError(f"{label} cryptcheck did not verify every original")


def back_up_destination(rclone, destination, snapshot, manifest):
    destination.verify()
    snapshot.verify()
    if destination.lifecycle_remote is not None:
        verify_b2_lifecycle(rclone, destination)
    initialize_destination(rclone, destination, snapshot)
    if snapshot.files:
        destination.verify()
        snapshot.verify()
        rclone.run(
            f"{destination.label} original copy",
            ["copy", snapshot.root, f"{destination.remote}:", "--files-from-raw", manifest,
             "--immutable", "--no-update-modtime", "--no-traverse"],
        )
        destination.verify()
        snapshot.verify()
        result = rclone.run(
            f"{destination.label} cryptcheck",
            ["cryptcheck", snapshot.root, f"{destination.remote}:",
             "--files-from-raw", manifest, "--one-way", "--log-level", "NOTICE", "--use-json-log"],
        )
        verify_cryptcheck_summary(result, len(snapshot.files), destination.label)
    verify_destination_marker(rclone, destination, snapshot)
    snapshot.verify()
    destination.verify()
    log(f"{destination.label} backup verified: {len(snapshot.files)} published originals")


class BackupMonitoring:
    def __init__(self, state_dir):
        self.state_dir = state_dir
        self.pending = {}
        self.failed = False

    def record(self, check, event, run_id):
        if self.state_dir is None:
            return
        try:
            monitor_status.record(self.state_dir, check, event, run_id)
        except (OSError, monitor_status.MonitoringError) as error:
            self.failed = True
            suffix = f" (errno {error.errno})" if isinstance(error, OSError) else ""
            log(f"ERROR could not record backup monitoring status{suffix}")

    def start(self):
        if self.state_dir is None:
            return
        for check in ("original-local", "original-b2"):
            run_id = str(uuid.uuid4())
            self.pending[check] = run_id
            self.record(check, "start", run_id)

    def finish(self, check, event):
        run_id = self.pending.pop(check, None)
        if run_id is not None:
            self.record(check, event, run_id)

    def fail_unfinished(self):
        for check in list(self.pending):
            self.finish(check, "failure")


def perform_backup(options, monitoring):
    with contextlib.ExitStack() as stack:
        source_mount = stack.enter_context(contextlib.closing(open_mount(options.source_volume, "source volume")))
        snapshot = inventory_source(options.source_root, options.source_id, source_mount)
        if snapshot.legacy_count:
            log(f"source includes {snapshot.legacy_count} legacy originals without a storage identity")
        with tempfile.TemporaryDirectory(prefix="dvu-original-backup-") as temporary:
            config = os.path.join(temporary, "rclone.conf")
            copy_private_config(options.rclone_config, config)
            rclone = Rclone(options.rclone, config, rclone_environment(options.password_helper))
            configs = rclone.configs()
            manifest = os.path.join(temporary, "originals.txt")
            with open(manifest, "x", encoding="ascii", newline="\n") as output:
                for name in sorted(snapshot.files):
                    output.write(name + "\n")

            failures = []
            try:
                with local_destination(configs, options, source_mount) as destination:
                    back_up_destination(rclone, destination, snapshot, manifest)
                monitoring.finish("original-local", "success")
            except BackupError as error:
                failures.append("local")
                monitoring.finish("original-local", "failure")
                log(f"ERROR local backup: {error}")
            except OSError as error:
                failures.append("local")
                monitoring.finish("original-local", "failure")
                log(f"ERROR local backup: filesystem operation failed (errno {error.errno})")
            try:
                destination = cloud_destination(configs, options)
                back_up_destination(rclone, destination, snapshot, manifest)
                monitoring.finish("original-b2", "success")
            except BackupError as error:
                failures.append("B2")
                monitoring.finish("original-b2", "failure")
                log(f"ERROR B2 backup: {error}")
            except OSError as error:
                failures.append("B2")
                monitoring.finish("original-b2", "failure")
                log(f"ERROR B2 backup: filesystem operation failed (errno {error.errno})")
            if failures:
                raise BackupError("backup incomplete: " + ", ".join(failures))


def execute(options):
    with backup_lock():
        monitoring = BackupMonitoring(options.monitor_state_dir)
        monitoring.start()
        try:
            perform_backup(normalize_options(options), monitoring)
        finally:
            monitoring.fail_unfinished()
        if monitoring.failed:
            raise BackupError("backup completed but its monitoring status could not be recorded")


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--source-volume", required=True, help="mounted volume containing the source root")
    result.add_argument("--source-root", required=True, help="the server's STORAGE_LOCAL_ROOT")
    result.add_argument("--source-id", required=True, help="expected UUID in the source storage marker")
    result.add_argument("--backup-volume", required=True, help="separate mounted external backup volume")
    result.add_argument("--backup-volume-id", required=True, help="expected UUID in the backup volume marker")
    result.add_argument("--local-remote", required=True, help="local crypt remote name, without ':'")
    result.add_argument("--b2-remote", required=True, help="B2 crypt remote name, without ':'")
    result.add_argument("--rclone-config", required=True, help="private encrypted rclone configuration")
    result.add_argument("--password-helper", required=True, help="executable that retrieves the config password")
    result.add_argument("--rclone", default="rclone", help="rclone executable")
    result.add_argument("--monitor-state-dir", help="private monitoring state directory")
    result.add_argument("--print-launchd", action="store_true", help="print an hourly LaunchAgent plist")
    return result


def normalize_options(options):
    for name in ("source_volume", "source_root", "backup_volume", "rclone_config", "password_helper"):
        setattr(options, name, absolute_path(getattr(options, name), name.replace("_", " ")))
    if options.monitor_state_dir is not None:
        options.monitor_state_dir = absolute_path(options.monitor_state_dir, "monitoring state directory")
    options.source_id = valid_uuid(options.source_id, "source identity")
    options.backup_volume_id = valid_uuid(options.backup_volume_id, "backup volume identity")
    options.local_remote = valid_remote(options.local_remote, "local remote")
    options.b2_remote = valid_remote(options.b2_remote, "B2 remote")
    if options.local_remote == options.b2_remote:
        raise BackupError("local and B2 crypt remotes must be different")
    binary = shutil.which(options.rclone)
    if binary is None:
        raise BackupError("rclone executable was not found")
    options.rclone = os.path.abspath(binary)
    return options


def launchd_plist(options):
    arguments = [sys.executable, os.path.abspath(__file__)]
    for name in (
        "source_volume", "source_root", "source_id", "backup_volume", "backup_volume_id",
        "local_remote", "b2_remote", "rclone_config", "password_helper", "rclone",
    ):
        arguments.extend(["--" + name.replace("_", "-"), getattr(options, name)])
    if getattr(options, "monitor_state_dir", None) is not None:
        arguments.extend(["--monitor-state-dir", options.monitor_state_dir])
    logs = os.path.join(os.path.expanduser("~"), "Library", "Logs")
    return plistlib.dumps({
        "Label": LAUNCHD_LABEL,
        "ProgramArguments": arguments,
        "StartInterval": 3600,
        "StandardOutPath": os.path.join(logs, LAUNCHD_LABEL + ".out.log"),
        "StandardErrorPath": os.path.join(logs, LAUNCHD_LABEL + ".err.log"),
    }, sort_keys=False)


def main(argv=None):
    options = parser().parse_args(argv)
    try:
        if options.print_launchd:
            options = normalize_options(options)
            sys.stdout.buffer.write(launchd_plist(options))
            return 0
        log("starting originals backup")
        execute(options)
        log("originals backup complete")
        return 0
    except BackupError as error:
        log(f"ERROR {error}")
        return 1
    except OSError as error:
        log(f"ERROR filesystem operation failed (errno {error.errno})")
        return 1


if __name__ == "__main__":
    sys.exit(main())

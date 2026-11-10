#!/usr/bin/env python3
"""Write private, atomic status receipts for independently scheduled jobs."""

import datetime
import fcntl
import json
import os
import re
import stat
import uuid


CHECK_ID = re.compile(r"^[a-z][a-z0-9-]{0,63}$")
ARCHIVE_NAME = re.compile(r"^directvideo_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}\.sql\.gz\.gpg$")
MAX_STATE_BYTES = 16384


class MonitoringError(Exception):
    pass


def _private_file(fd):
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise MonitoringError("monitoring state file is not private")
    return info


def _open_directory(state_dir):
    if not isinstance(state_dir, str) or not os.path.isabs(state_dir):
        raise MonitoringError("monitoring state directory must be absolute")
    fd = os.open(state_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise MonitoringError("monitoring state directory is not private")
        return fd
    except (OSError, MonitoringError):
        os.close(fd)
        raise


def _validate_check_id(check_id):
    if not isinstance(check_id, str) or not CHECK_ID.fullmatch(check_id):
        raise MonitoringError("monitoring check identifier is invalid")


def valid_archive(archive):
    return (
        isinstance(archive, dict)
        and set(archive) == {"name", "sizeBytes", "mtimeNs"}
        and isinstance(archive["name"], str)
        and ARCHIVE_NAME.fullmatch(archive["name"]) is not None
        and isinstance(archive["sizeBytes"], str)
        and re.fullmatch(r"[1-9][0-9]*", archive["sizeBytes"]) is not None
        and isinstance(archive["mtimeNs"], str)
        and re.fullmatch(r"[0-9]+", archive["mtimeNs"]) is not None
    )


def _read_state(directory_fd, filename):
    try:
        fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
    except FileNotFoundError:
        return {"version": 1}
    try:
        info = _private_file(fd)
        if info.st_size > MAX_STATE_BYTES:
            raise MonitoringError("monitoring state file is too large")
        with os.fdopen(fd, "rb") as source:
            fd = -1
            data = source.read(MAX_STATE_BYTES + 1)
        if len(data) > MAX_STATE_BYTES:
            raise MonitoringError("monitoring state file is too large")
        try:
            state = json.loads(data)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise MonitoringError("monitoring state is invalid") from error
        if not isinstance(state, dict) or state.get("version") != 1:
            raise MonitoringError("monitoring state has an unsupported format")
        return state
    finally:
        if fd != -1:
            os.close(fd)


def read(state_dir, check_id):
    _validate_check_id(check_id)
    directory_fd = _open_directory(state_dir)
    try:
        return _read_state(directory_fd, check_id + ".json")
    finally:
        os.close(directory_fd)


def acquire_database_lock(state_dir):
    directory_fd = _open_directory(state_dir)
    try:
        fd = os.open(
            "database-jobs.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd
        )
    finally:
        os.close(directory_fd)
    try:
        _private_file(fd)
        fcntl.flock(fd, fcntl.LOCK_EX)
        return fd
    except (OSError, MonitoringError):
        os.close(fd)
        raise


def record(state_dir, check_id, event, run_id, now=None, *, stable_source_archive=False, archive=None):
    _validate_check_id(check_id)
    if event not in ("start", "success", "failure"):
        raise MonitoringError("monitoring event is invalid")
    if not isinstance(stable_source_archive, bool) or (stable_source_archive and event != "success"):
        raise MonitoringError("monitoring archive evidence is invalid")
    if archive is not None and (event != "success" or not valid_archive(archive)):
        raise MonitoringError("monitoring archive metadata is invalid")
    try:
        run_id = str(uuid.UUID(run_id))
    except (ValueError, TypeError, AttributeError) as error:
        raise MonitoringError("monitoring run identifier is invalid") from error
    now = now or datetime.datetime.now(datetime.timezone.utc)
    if now.tzinfo is None or now.utcoffset() is None:
        raise MonitoringError("monitoring timestamp must have a timezone")
    timestamp = now.astimezone(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")

    directory_fd = _open_directory(state_dir)
    try:
        lock_fd = os.open(
            check_id + ".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd
        )
        try:
            _private_file(lock_fd)
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            state = _read_state(directory_fd, check_id + ".json")
            if event == "start":
                state["lastStartedAt"] = timestamp
                state["currentRunId"] = run_id
            else:
                state["lastCompletedAt"] = timestamp
                state["lastOutcome"] = event
                state["lastSuccessAt" if event == "success" else "lastFailureAt"] = timestamp
                if event == "success":
                    if stable_source_archive:
                        state["stableSourceArchive"] = True
                    else:
                        state.pop("stableSourceArchive", None)
                    if archive is None:
                        state.pop("lastArchive", None)
                    else:
                        state["lastArchive"] = dict(archive)
                if state.get("currentRunId") == run_id:
                    state["currentRunId"] = None

            data = json.dumps(state, separators=(",", ":"), sort_keys=True).encode("utf-8") + b"\n"
            if len(data) > MAX_STATE_BYTES:
                raise MonitoringError("monitoring state is too large")
            temporary = "." + check_id + "-" + str(uuid.uuid4()) + ".tmp"
            temp_fd = os.open(
                temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd
            )
            try:
                with os.fdopen(temp_fd, "wb") as target:
                    temp_fd = -1
                    target.write(data)
                    target.flush()
                    os.fsync(target.fileno())
                os.replace(temporary, check_id + ".json", src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
            finally:
                if temp_fd != -1:
                    os.close(temp_fd)
                try:
                    os.unlink(temporary, dir_fd=directory_fd)
                except FileNotFoundError:
                    pass
        finally:
            os.close(lock_fd)
    finally:
        os.close(directory_fd)

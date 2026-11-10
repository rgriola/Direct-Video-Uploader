#!/usr/bin/env python3
"""Run an existing scheduled job and record its outcome without capturing its output."""

import argparse
import datetime
import os
import signal
import stat
import subprocess
import sys
import time
import uuid

import monitor_status


def recent_archives(directory, max_age_seconds):
    info = os.lstat(directory)
    if not stat.S_ISDIR(info.st_mode):
        raise monitor_status.MonitoringError("database backup directory is not a directory")
    now = time.time()
    archives = {}
    with os.scandir(directory) as entries:
        for entry in entries:
            if not monitor_status.ARCHIVE_NAME.fullmatch(entry.name):
                continue
            try:
                details = entry.stat(follow_symlinks=False)
            except FileNotFoundError:
                continue
            if (stat.S_ISREG(details.st_mode) and details.st_size > 0
                    and details.st_mtime <= now + 60 and now - details.st_mtime < max_age_seconds):
                archives[entry.name] = (details.st_dev, details.st_ino, details.st_size, details.st_mtime_ns)
    return archives


def recorded_archive(state_dir, archives, max_age_seconds):
    state = monitor_status.read(state_dir, "database-local")
    archive = state.get("lastArchive")
    if (state.get("lastOutcome") != "success" or state.get("currentRunId") is not None
            or state.get("lastSuccessAt") != state.get("lastCompletedAt")
            or not monitor_status.valid_archive(archive)):
        raise monitor_status.MonitoringError("a completed local database backup is not recorded")
    try:
        completed = datetime.datetime.strptime(state["lastSuccessAt"], "%Y-%m-%dT%H:%M:%S.%fZ")
        completed = completed.replace(tzinfo=datetime.timezone.utc).timestamp()
    except (KeyError, TypeError, ValueError) as error:
        raise monitor_status.MonitoringError("local database backup time is invalid") from error
    age = time.time() - completed
    if age < -60 or age >= max_age_seconds:
        raise monitor_status.MonitoringError("local database backup is stale")
    details = archives.get(archive["name"])
    if (details is None or str(details[2]) != archive["sizeBytes"] or str(details[3]) != archive["mtimeNs"]):
        raise monitor_status.MonitoringError("the recorded database archive is unavailable or changed")
    return archive["name"]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", required=True, help="private monitoring state directory")
    parser.add_argument("--check", required=True, help="monitoring check identifier")
    archives = parser.add_mutually_exclusive_group()
    archives.add_argument("--created-archive-dir", help="record the archive created by a local database backup")
    archives.add_argument("--require-archive-dir", help="require a recorded local database archive for offsite sync")
    parser.add_argument("--archive-max-age-hours", type=int, default=36, help="maximum source archive age in hours")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="command and arguments after --")
    options = parser.parse_args(argv)
    command = options.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("a command is required after --")
    archive_dir = options.require_archive_dir or options.created_archive_dir
    if archive_dir and not os.path.isabs(archive_dir):
        parser.error("the archive directory must be absolute")
    if options.archive_max_age_hours < 1 or options.archive_max_age_hours > 24 * 365:
        parser.error("--archive-max-age-hours must be between 1 and 8760")
    if options.created_archive_dir and options.check != "database-local":
        parser.error("--created-archive-dir requires the database-local check")
    if options.require_archive_dir and options.check != "database-offsite":
        parser.error("--require-archive-dir requires the database-offsite check")

    lock_fd = None
    lock_failed = False
    if archive_dir:
        try:
            lock_fd = monitor_status.acquire_database_lock(options.state_dir)
        except (OSError, monitor_status.MonitoringError) as error:
            lock_failed = True
            suffix = f" (errno {error.errno})" if isinstance(error, OSError) else ""
            print(f"ERROR: could not lock monitored database jobs{suffix}", file=sys.stderr, flush=True)
    try:
        return run(options, command, archive_dir, lock_fd, lock_failed)
    finally:
        if lock_fd is not None:
            os.close(lock_fd)


def run(options, command, archive_dir, lock_fd, lock_failed):
    run_id = str(uuid.uuid4())
    recording_failed = False

    def report(event, stable_source_archive=False, archive=None):
        nonlocal recording_failed
        try:
            monitor_status.record(
                options.state_dir, options.check, event, run_id,
                stable_source_archive=stable_source_archive, archive=archive,
            )
        except (OSError, monitor_status.MonitoringError) as error:
            recording_failed = True
            suffix = f" (errno {error.errno})" if isinstance(error, OSError) else ""
            print(f"ERROR: could not record monitoring status{suffix}", file=sys.stderr, flush=True)

    report("start")
    if options.require_archive_dir and (lock_failed or recording_failed):
        print(
            "ERROR: offsite sync was not started without monitoring state and the database job lock",
            file=sys.stderr, flush=True,
        )
        report("failure")
        return 1
    archives_before = None
    source_name = None
    if archive_dir:
        try:
            archives_before = recent_archives(archive_dir, options.archive_max_age_hours * 3600)
            if options.require_archive_dir:
                source_name = recorded_archive(options.state_dir, archives_before, options.archive_max_age_hours * 3600)
        except FileNotFoundError as error:
            if options.created_archive_dir:
                archives_before = {}
            else:
                print(f"ERROR: could not inspect source database archives (errno {error.errno})", file=sys.stderr, flush=True)
                report("failure")
                return 1
        except (OSError, monitor_status.MonitoringError) as error:
            suffix = f" (errno {error.errno})" if isinstance(error, OSError) else ""
            print(f"ERROR: could not inspect source database archives{suffix}", file=sys.stderr, flush=True)
            if options.require_archive_dir:
                print("ERROR: no confirmed recent local backup; offsite sync was not started", file=sys.stderr, flush=True)
                report("failure")
                return 1
    try:
        child = subprocess.Popen(
            command, start_new_session=True, pass_fds=(lock_fd,) if lock_fd is not None else ()
        )
    except OSError as error:
        print(f"ERROR: scheduled job could not start (errno {error.errno})", file=sys.stderr, flush=True)
        report("failure")
        return 1

    interrupted = False

    def forward(signum, _frame):
        nonlocal interrupted
        interrupted = True
        try:
            os.killpg(child.pid, signum)
        except ProcessLookupError:
            pass

    previous = {sig: signal.signal(sig, forward) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        result = child.wait()
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    stable_source_archive = False
    created_archive = None
    if result == 0 and not interrupted and archive_dir:
        try:
            archives_after = recent_archives(archive_dir, options.archive_max_age_hours * 3600)
            if options.require_archive_dir:
                stable_source_archive = archives_before is not None and (
                    archives_before.get(source_name) == archives_after.get(source_name)
                    and source_name in archives_after
                )
            elif archives_before is not None:
                created = [
                    (name, details) for name, details in archives_after.items()
                    if archives_before.get(name) != details
                ]
                if len(created) == 1:
                    name, details = created[0]
                    created_archive = {"name": name, "sizeBytes": str(details[2]), "mtimeNs": str(details[3])}
        except (OSError, monitor_status.MonitoringError) as error:
            suffix = f" (errno {error.errno})" if isinstance(error, OSError) else ""
            print(f"ERROR: could not inspect source database archives{suffix}", file=sys.stderr, flush=True)
        if options.require_archive_dir and not stable_source_archive:
            print("ERROR: no recent source database archive was stable during the job", file=sys.stderr, flush=True)
        if options.created_archive_dir and created_archive is None:
            print("ERROR: could not identify the database archive created by the job", file=sys.stderr, flush=True)
    job_succeeded = result == 0 and not interrupted and (
        not options.require_archive_dir or stable_source_archive
    ) and (not options.created_archive_dir or (created_archive is not None and not lock_failed))
    report("success" if job_succeeded else "failure", stable_source_archive=stable_source_archive, archive=created_archive)
    if interrupted or result < 0:
        return 1
    if result != 0:
        return result
    if not job_succeeded:
        return 1
    return 1 if recording_failed else 0


if __name__ == "__main__":
    sys.exit(main())

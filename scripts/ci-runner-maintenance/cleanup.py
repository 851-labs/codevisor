#!/usr/bin/env python3
"""Remove the two known CI leaks, with the runner idle and its listener paused."""

import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time


class Busy(RuntimeError):
    pass


SQLITE_FILE = re.compile(
    r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\.db(?:-wal|-shm)?"
)
FFMPEG_FILE = re.compile(r"[0-9a-f]{128}\.(?:body|json)")


def processes():
    result = subprocess.run(
        ["/bin/ps", "-U", str(os.getuid()), "-o", "pid=,comm="],
        check=True, capture_output=True, text=True,
    )
    return [(int(pid), command) for pid, command in
            (line.strip().split(None, 1) for line in result.stdout.splitlines())]


def require_idle(entries):
    active = [command for _, command in entries if
              Path(command).name in ("Runner.Worker", "xcodebuild", "swift-test")
              or ".xctest/" in command]
    if active:
        raise Busy("CI jobs or tests are still running")


@contextlib.contextmanager
def idle_runner(runner):
    entries = processes()
    require_idle(entries)
    listeners = [pid for pid, command in entries if
                 command.startswith(str(runner) + "/")
                 and Path(command).name == "Runner.Listener"]
    if len(listeners) != 1:
        raise RuntimeError("Expected exactly one runner listener")
    pid = listeners[0]
    try:
        os.kill(pid, signal.SIGSTOP)
        deadline = time.monotonic() + 5
        while True:
            state = subprocess.run(
                ["/bin/ps", "-p", str(pid), "-o", "stat="],
                check=True, capture_output=True, text=True,
            ).stdout
            if "T" in state:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("Runner listener did not pause")
            time.sleep(0.05)
        require_idle(processes())
        yield
    finally:
        os.kill(pid, signal.SIGCONT)


def inventory(targets):
    selected = []
    skipped = 0
    for directory, pattern in targets:
        if directory.is_symlink():
            raise RuntimeError("Refusing a symlinked cleanup directory: " + str(directory))
        if not directory.exists():
            continue
        for entry in directory.iterdir():
            if entry.is_symlink() or not entry.is_file() or not pattern.fullmatch(entry.name):
                skipped += 1
                continue
            selected.append((entry, entry.stat().st_blocks * 512))
    return selected, skipped


def require_closed(targets):
    result = subprocess.run(
        ["/usr/sbin/lsof", "-nP", "-a", "-u", str(os.getuid()), "-Fn"],
        capture_output=True, text=True, timeout=20,
    )
    if result.returncode not in (0, 1) or result.stderr.strip():
        raise RuntimeError("Could not verify that cleanup files are closed")
    roots = [directory.resolve() for directory, _ in targets]
    for line in result.stdout.splitlines():
        if not line.startswith("n/"):
            continue
        path = Path(line[1:]).resolve()
        if any(root == path or root in path.parents for root in roots):
            raise Busy("A cleanup directory still has open files")


def clean(targets, apply, runner):
    def perform():
        selected, skipped = inventory(targets)
        before = shutil.disk_usage(runner.parent).free
        if apply:
            require_closed(targets)
            for path, _ in selected:
                path.unlink()
        return {
            "applied": apply,
            "targets": [str(path) for path, _ in targets],
            "files": len(selected),
            "allocated_bytes": sum(size for _, size in selected),
            "unrecognized_entries_preserved": skipped,
            "free_before_bytes": before,
            "free_after_bytes": shutil.disk_usage(runner.parent).free,
        }

    if not apply:
        return perform()
    with idle_runner(runner):
        return perform()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Delete files; default is a report")
    parser.add_argument("--wait-idle", type=int, default=0, metavar="SECONDS")
    args = parser.parse_args()
    runner = Path.home() / "actions-runner"
    temporary = subprocess.check_output(
        ["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], text=True,
    ).strip()
    targets = [
        (Path.home() / "Library/Caches/ffmpeg-static-nodejs", FFMPEG_FILE),
        (Path(temporary) / "co.pointfree.SQLiteData", SQLITE_FILE),
    ]
    lock = Path(__file__).resolve().with_suffix(".lock")
    with lock.open("a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        deadline = time.monotonic() + args.wait_idle
        next_message = 0
        while True:
            try:
                print(json.dumps(clean(targets, args.apply, runner), indent=2), flush=True)
                return
            except Busy as error:
                if time.monotonic() >= deadline:
                    raise
                if time.monotonic() >= next_message:
                    print(str(error) + "; waiting for an idle boundary", flush=True)
                    next_message = time.monotonic() + 15
                time.sleep(min(0.5, max(0, deadline - time.monotonic())))


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    main()

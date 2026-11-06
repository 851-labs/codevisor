import collections
import datetime as dt
import os
import shutil
import stat
import sys
import time

GB = 1000**3
DAY_SECONDS = 24 * 60 * 60
TARGET_FREE_BYTES = 40 * GB
MINIMUM_FREE_BYTES = 20 * GB
STALE_AFTER_SECONDS = 14 * DAY_SECONDS
DIAG_RETENTION_SECONDS = 7 * DAY_SECONDS
SCAN_DEPTH = 3
SCAN_LIMIT = 2000


class Layout:
    def __init__(self, home, runner, protected):
        self.home = home
        self.runner = runner
        self.protected = [os.path.realpath(path) for path in protected]

    @property
    def diag(self):
        return os.path.join(self.runner, "_diag")

    def unit_parents(self):
        work = os.path.join(self.runner, "_work")
        workspaces = [path for path in child_directories(work) if not is_runner_owned(path)]
        return (
            workspaces
            + child_directories(os.path.join(work, "_tool"))
            + child_directories(os.path.join(self.home, ".codevisor-development", "artifacts"))
            + [
                os.path.join(self.home, "Library", "Caches"),
                os.path.join(self.home, "Library", "Developer", "Xcode", "DerivedData"),
            ]
        )


class Unit:
    def __init__(self, path, last_used):
        self.path = path
        self.last_used = last_used


def main():
    home = os.path.expanduser("~")
    layout = Layout(home, os.path.join(home, "actions-runner"), protected_paths(os.environ))
    try:
        return clean(layout, time.time(), lambda: shutil.disk_usage(home).free, print)
    except Exception as error:
        print(f"Runner janitor skipped: {error!r}")
        return 0


def clean(layout, now, free_bytes, log):
    log(f"Runner disk: {gigabytes(free_bytes())} free before cleanup")
    remove_expired_logs(layout.diag, now)

    units = collect_units(layout)
    stale = [unit for unit in units if now - unit.last_used > STALE_AFTER_SECONDS]
    for unit in stale:
        remove_unit(unit, f"unused for over {STALE_AFTER_SECONDS // DAY_SECONDS} days", log)

    remaining = sorted(
        (unit for unit in units if unit not in stale), key=lambda unit: unit.last_used
    )
    while free_bytes() < TARGET_FREE_BYTES and remaining:
        remove_unit(remaining.pop(0), "least recently used", log)

    free = free_bytes()
    log(f"Runner disk: {gigabytes(free)} free after cleanup")
    if free >= MINIMUM_FREE_BYTES:
        return 0

    log(
        f"Runner has only {gigabytes(free)} free after removing every cache; "
        f"jobs need {gigabytes(MINIMUM_FREE_BYTES)}."
    )
    return 1


def collect_units(layout):
    units = []
    for parent in layout.unit_parents():
        for path in child_paths(parent):
            if is_disposable(path, layout.protected):
                units.append(Unit(path, last_used(path)))
    return units


def is_disposable(path, protected):
    name = os.path.basename(path)
    if name.startswith(".") or name.startswith("com.apple."):
        return False

    resolved = os.path.realpath(path)
    return not any(overlaps(resolved, kept) for kept in protected)


def overlaps(path, other):
    return path == other or other.startswith(path + os.sep) or path.startswith(other + os.sep)


def last_used(path):
    newest = 0.0
    pending = collections.deque([(path, 0)])
    scanned = 0
    while pending and scanned < SCAN_LIMIT:
        current, depth = pending.popleft()
        scanned += 1
        info = lstat_or_none(current)
        if info is None:
            continue

        if not stat.S_ISDIR(info.st_mode):
            newest = max(newest, info.st_mtime, info.st_atime)
            continue

        newest = max(newest, info.st_mtime)
        if depth < SCAN_DEPTH:
            pending.extend((child, depth + 1) for child in child_paths(current))
    return newest


def remove_unit(unit, reason, log):
    try:
        remove_path(unit.path)
    except OSError as error:
        log(f"Could not remove {unit.path}: {error}")
        return

    log(f"Removed {unit.path} ({reason}; last used {date_of(unit.last_used)})")


def remove_path(path):
    if is_real_directory(path):
        shutil.rmtree(path, onerror=retry_writable)
    else:
        os.unlink(path)


def retry_writable(function, path, _error):
    os.chmod(os.path.dirname(path), stat.S_IRWXU)
    function(path)


def remove_expired_logs(directory, now):
    for path in child_paths(directory):
        if is_expired_log(lstat_or_none(path), now):
            unlink_quietly(path)


def is_expired_log(info, now):
    if info is None or not stat.S_ISREG(info.st_mode):
        return False

    return now - info.st_mtime > DIAG_RETENTION_SECONDS


def unlink_quietly(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def protected_paths(environ):
    workspace = environ.get("GITHUB_WORKSPACE")
    return [workspace] if workspace else []


def is_runner_owned(path):
    return os.path.basename(path).startswith("_")


def child_directories(parent):
    return [path for path in child_paths(parent) if is_real_directory(path)]


def is_real_directory(path):
    return os.path.isdir(path) and not os.path.islink(path)


def child_paths(parent):
    try:
        with os.scandir(parent) as entries:
            return sorted(entry.path for entry in entries)
    except (FileNotFoundError, NotADirectoryError, PermissionError):
        return []


def lstat_or_none(path):
    try:
        return os.lstat(path)
    except OSError:
        return None


def gigabytes(byte_count):
    return f"{byte_count / GB:.1f} GB"


def date_of(timestamp):
    return dt.datetime.fromtimestamp(timestamp).strftime("%Y-%m-%d")


if __name__ == "__main__":
    sys.exit(main())

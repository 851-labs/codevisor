#!/usr/bin/env python3
"""Per-minute CPU/memory sampler for a self-hosted CI runner, plus a tiny
HTTP server that exposes the samples and the dashboard to the tailnet.

Stdlib only (runs on the Xcode-bundled Python 3.9). Data lives in daily UTC
CSV files under ./data next to this script and is pruned after RETENTION_DAYS.
"""

import csv
import ctypes
import datetime as dt
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(HERE, "data")
PORT = 9187
RETENTION_DAYS = 35
TICK_SECONDS = 5

COLUMNS = [
    "ts",
    "cpu_user",
    "cpu_sys",
    "cpu_peak",
    "load1",
    "mem_app_gb",
    "mem_wired_gb",
    "mem_compressed_gb",
    "mem_cached_gb",
    "mem_free_gb",
    "mem_avail_pct",
    "swap_used_gb",
    "disk_free_gb",
    "busy",
]

ALLOWED_NETS = [
    ipaddress.ip_network("100.64.0.0/10"),
    ipaddress.ip_network("fd7a:115c:a1e0::/48"),
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("::1/128"),
]


_libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
_libc.mach_host_self.restype = ctypes.c_uint32
_HOST = _libc.mach_host_self()
_HOST_CPU_LOAD_INFO = 3


def cpu_ticks():
    """Cumulative (user, system, idle, nice) ticks across all cores."""
    info = (ctypes.c_uint32 * 4)()
    count = ctypes.c_uint32(4)
    kr = _libc.host_statistics(_HOST, _HOST_CPU_LOAD_INFO, info, ctypes.byref(count))
    if kr != 0:
        raise OSError("host_statistics failed: %d" % kr)
    return tuple(info)


def tick_delta(a, b):
    return [(y - x) % 2**32 for x, y in zip(a, b)]


def sysctl(*names):
    out = subprocess.run(["/usr/sbin/sysctl", "-n"] + list(names),
                         capture_output=True, text=True, check=True).stdout
    return out.strip().splitlines()


def runner_job_alive():
    return subprocess.run(["/usr/bin/pgrep", "-x", "Runner.Worker"],
                          capture_output=True).returncode == 0


def memory_sample():
    out = subprocess.run(["/usr/bin/vm_stat"], capture_output=True, text=True, check=True).stdout
    page = int(re.search(r"page size of (\d+) bytes", out).group(1))
    pages = {k.strip().strip('"'): int(v) for k, v in re.findall(r"^([^:\n]+):\s+(\d+)\.$", out, re.M)}
    gb = lambda n: n * page / 2**30
    level, swap = sysctl("kern.memorystatus_level", "vm.swapusage")
    swap_used = re.search(r"used = ([\d.]+)M", swap)
    return {
        "mem_app_gb": gb(pages["Anonymous pages"] - pages["Pages purgeable"]),
        "mem_wired_gb": gb(pages["Pages wired down"]),
        "mem_compressed_gb": gb(pages["Pages occupied by compressor"]),
        "mem_cached_gb": gb(pages["File-backed pages"] + pages["Pages purgeable"]),
        "mem_free_gb": gb(pages["Pages free"] + pages["Pages speculative"]),
        "mem_avail_pct": float(level),
        "swap_used_gb": float(swap_used.group(1)) / 1024 if swap_used else 0.0,
    }


def day_path(ts):
    return os.path.join(DATA_DIR, dt.datetime.utcfromtimestamp(ts).strftime("%Y-%m-%d") + ".csv")


def append_row(row):
    path = day_path(row["ts"])
    new = not os.path.exists(path)
    with open(path, "a", newline="") as f:
        w = csv.writer(f)
        if new:
            w.writerow(COLUMNS)
        w.writerow([round(row[c], 3) if isinstance(row[c], float) else row[c] for c in COLUMNS])


def prune():
    cutoff = (dt.datetime.utcnow() - dt.timedelta(days=RETENTION_DAYS)).strftime("%Y-%m-%d")
    for name in os.listdir(DATA_DIR):
        if name.endswith(".csv") and name[:-4] < cutoff:
            os.remove(os.path.join(DATA_DIR, name))


def sampler():
    prev = cpu_ticks()
    while True:
        start = prev
        peak, ticks, busy_ticks = 0.0, 0, 0
        minute_end = (int(time.time()) // 60 + 1) * 60
        while time.time() < minute_end:
            time.sleep(min(TICK_SECONDS, max(0.05, minute_end - time.time())))
            cur = cpu_ticks()
            d = tick_delta(prev, cur)
            total = sum(d) or 1
            peak = max(peak, 100.0 * (d[0] + d[1] + d[3]) / total)
            prev = cur
            ticks += 1
            try:
                busy_ticks += runner_job_alive()
            except OSError:
                pass
        d = tick_delta(start, prev)
        total = sum(d) or 1
        row = {
            "ts": minute_end,
            "cpu_user": 100.0 * (d[0] + d[3]) / total,
            "cpu_sys": 100.0 * d[1] / total,
            "cpu_peak": peak,
            "load1": os.getloadavg()[0],
            "disk_free_gb": shutil.disk_usage("/System/Volumes/Data").free / 2**30,
            "busy": busy_ticks / max(1, ticks),
        }
        try:
            row.update(memory_sample())
            append_row(row)
            if minute_end % 3600 == 0:
                prune()
        except Exception as e:
            print("sample failed:", repr(e), flush=True)



def read_rows(since, until):
    rows = []
    day = dt.datetime.utcfromtimestamp(since).date()
    last = dt.datetime.utcfromtimestamp(until).date()
    while day <= last:
        path = os.path.join(DATA_DIR, day.isoformat() + ".csv")
        if os.path.exists(path):
            with open(path, newline="") as f:
                r = csv.reader(f)
                header = next(r, None)
                idx = [header.index(c) if c in header else None for c in COLUMNS]
                for line in r:
                    try:
                        vals = [float(line[i]) if i is not None else None for i in idx]
                    except (ValueError, IndexError):
                        continue
                    if since <= vals[0] <= until:
                        rows.append(vals)
        day += dt.timedelta(days=1)
    return rows


def bucket(rows, step):
    """Average rows into `step`-second buckets; cpu_peak keeps its max."""
    if step <= 60:
        return rows
    peak_i = COLUMNS.index("cpu_peak")
    out, cur_key, acc = [], None, []

    def flush():
        n = len(acc)
        merged = [cur_key + step]
        for i in range(1, len(COLUMNS)):
            vals = [r[i] for r in acc if r[i] is not None]
            if not vals:
                merged.append(None)
            elif i == peak_i:
                merged.append(max(vals))
            else:
                merged.append(sum(vals) / len(vals))
        merged.append(n)
        out.append(merged)

    for r in rows:
        key = int((r[0] - 1) // step * step)
        if key != cur_key and acc:
            flush()
            acc = []
        cur_key = key
        acc.append(r)
    if acc:
        flush()
    return out



class Handler(BaseHTTPRequestHandler):
    server_version = "runner-metrics"

    def log_message(self, fmt, *args):
        pass

    def allowed(self):
        try:
            ip = ipaddress.ip_address(self.client_address[0].split("%")[0])
            if ip.version == 6 and ip.ipv4_mapped:
                ip = ip.ipv4_mapped
        except ValueError:
            return False
        return any(ip in net for net in ALLOWED_NETS)

    def cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Private-Network", "true")

    def send(self, code, body, ctype):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.cors()
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self.send_response(204)
        self.cors()
        self.send_header("Access-Control-Allow-Methods", "GET")
        self.end_headers()

    def do_GET(self):
        if not self.allowed():
            return self.send(403, "tailnet only\n", "text/plain")
        url = urlparse(self.path)
        if url.path in ("/", "/index.html"):
            with open(os.path.join(HERE, "index.html"), "rb") as f:
                return self.send(200, f.read(), "text/html; charset=utf-8")
        if url.path == "/api/metrics":
            q = parse_qs(url.query)
            now = int(time.time())
            until = int(q.get("until", [now])[0])
            since = int(q.get("since", [until - 86400])[0])
            step = max(60, int(q.get("step", [60])[0]))
            rows = bucket(read_rows(since, until), step)
            body = {
                "host": socket.gethostname().split(".")[0],
                "cores": os.cpu_count(),
                "memTotalGb": int(sysctl("hw.memsize")[0]) / 2**30,
                "diskTotalGb": shutil.disk_usage("/System/Volumes/Data").total / 2**30,
                "step": step,
                "columns": COLUMNS + (["n"] if step > 60 else []),
                "rows": [[round(v, 2) if isinstance(v, float) else v for v in r] for r in rows],
            }
            return self.send(200, json.dumps(body, separators=(",", ":")), "application/json")
        return self.send(404, "not found\n", "text/plain")


class DualStackServer(ThreadingHTTPServer):
    address_family = socket.AF_INET6
    daemon_threads = True

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


def main():
    os.makedirs(DATA_DIR, exist_ok=True)
    threading.Thread(target=sampler, daemon=True).start()
    DualStackServer(("::", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()

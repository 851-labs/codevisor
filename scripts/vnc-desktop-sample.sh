#!/usr/bin/env bash
# Measures a desktop provisioned by scripts/vnc-desktop.sh as the Codevisor
# client sees it (851-2322): `screen-sharing-rig vnc-sample` through an SSH
# tunnel to the localhost-only Xvnc, while the desktop runs a scripted
# workload. Prints one JSON line per workload:
#
#   idle    nothing but the desktop itself
#   drag    a terminal window moved back and forth at ~60 Hz (what a compositor's
#           shadows and redraws cost)
#   typing  keystrokes into that terminal, timed from send to the echo's update
#
#   scripts/vnc-desktop-sample.sh root@HOST [RIG_BINARY]
#
# Opens one scratch terminal on the desktop and closes it afterwards; nothing
# else on the desktop is touched. Keep the desktop otherwise still while it runs.
set -euo pipefail

target=${1:-}
[[ -n "$target" ]] || { echo "Usage: $0 user@host [rig-binary]" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
rig=${2:-$root/apps/screen-sharing-rig/.build/release/screen-sharing-rig}
[[ -x "$rig" ]] || { echo "Build the rig first: (cd apps/screen-sharing-rig && swift build -c release)" >&2; exit 2; }
display=${DISPLAY_NUMBER:-1}
local_port=${LOCAL_PORT:-15901}
seconds=${SECONDS_PER_WORKLOAD:-10}
keys=${KEYS:-40}
quality=${QUALITY:-}
quality_args=()
[[ -n "$quality" ]] && quality_args=(--quality "$quality")

remote() { ssh -o BatchMode=yes "$target" "export DISPLAY=:$display; $1"; }

ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -N -L "$local_port:127.0.0.1:$((5900 + display))" "$target" &
tunnel=$!
cleanup() {
  remote 'xdotool search --name "^vnc-sample$" windowclose 2>/dev/null || pkill -f "title=vnc-sample" || true' \
    >/dev/null 2>&1 || true
  kill "$tunnel" 2>/dev/null || true
}
trap cleanup EXIT
for _ in $(seq 1 50); do nc -z 127.0.0.1 "$local_port" 2>/dev/null && break; sleep 0.1; done

remote 'command -v xdotool >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -q xdotool >/dev/null'
remote 'setsid xfce4-terminal --disable-server --title=vnc-sample --geometry 80x20+200+150 >/dev/null 2>&1 < /dev/null &'
wid=$(remote 'xdotool search --sync --name "^vnc-sample$" | head -1')
remote "xdotool windowactivate --sync $wid"
sleep 1

sample() { "$rig" vnc-sample --host 127.0.0.1 --port "$local_port" ${quality_args[@]+"${quality_args[@]}"} "$@"; }

printf '{"workload":"idle",%s\n' "$(sample --seconds "$seconds" | cut -c2-)"

remote "end=\$((\$(date +%s) + $seconds + 3)); i=0
  while [ \$(date +%s) -lt \$end ]; do
    step=\$((i % 200)); [ \$step -ge 100 ] && step=\$((200 - step))
    xdotool windowmove $wid \$((200 + step * 6)) 150; sleep 0.016; i=\$((i + 1))
  done; echo \"drag: \$i moves\" >&2" &
drag=$!
sleep 1
printf '{"workload":"drag",%s\n' "$(sample --seconds "$seconds" | cut -c2-)"
wait "$drag"
remote "xdotool windowmove $wid 200 150; xdotool windowactivate --sync $wid"
sleep 1

printf '{"workload":"typing",%s\n' "$(sample --seconds 1 --keys "$keys" | cut -c2-)"

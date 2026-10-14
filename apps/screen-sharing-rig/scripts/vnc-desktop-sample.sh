#!/usr/bin/env bash
set -euo pipefail

target=${1:-}
[[ -n "$target" ]] || { echo "Usage: $0 user@host [rig-binary]" >&2; exit 2; }
root=$(cd "$(dirname "$0")/../../.." && pwd)
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

control=$(mktemp -u /tmp/codevisor-tunnel.XXXXXX)
ssh -f -N -M -S "$control" -o BatchMode=yes -o ExitOnForwardFailure=yes \
  -L "$local_port:127.0.0.1:$((5900 + display))" "$target"
cleanup() {
  remote 'xdotool search --name "^vnc-sample$" windowclose 2>/dev/null || pkill -f "title=vnc-sample" || true' \
    >/dev/null 2>&1 || true
  ssh -S "$control" -O exit "$target" >/dev/null 2>&1 || true
}
trap cleanup EXIT

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

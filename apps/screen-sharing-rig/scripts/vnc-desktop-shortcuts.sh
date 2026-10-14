#!/usr/bin/env bash
set -euo pipefail

target=${1:-}
[[ -n "$target" ]] || { echo "Usage: $0 user@host [rig-binary]" >&2; exit 2; }
root=$(cd "$(dirname "$0")/../../.." && pwd)
rig=${2:-$root/apps/screen-sharing-rig/.build/release/screen-sharing-rig}
[[ -x "$rig" ]] || { echo "Build the rig first: (cd apps/screen-sharing-rig && swift build -c release)" >&2; exit 2; }
display=${DISPLAY_NUMBER:-1}
local_port=${LOCAL_PORT:-15902}
nonce=$(date +%s)-$$
work=/tmp/codevisor-shortcuts-$nonce

remote() { ssh -o BatchMode=yes "$target" "export DISPLAY=:$display; $1"; }
session='export DBUS_SESSION_BUS_ADDRESS=$(tr "\0" "\n" < /proc/$(pgrep -o xfce4-panel)/environ | sed -n "s/^DBUS_SESSION_BUS_ADDRESS=//p")'

keys() { "$rig" vnc-keys --host 127.0.0.1 --port "$local_port" "$@" >/dev/null; }
clipboard() { remote 'xclip -o -selection clipboard 2>/dev/null' || true; }
failures=0
check() {
  if [[ "$2" == "$3" ]]; then echo "✔ $1"; else echo "✘ $1 — expected [$3], got [$2]"; failures=$((failures + 1)); fi
}

control=$(mktemp -u /tmp/codevisor-tunnel.XXXXXX)
ssh -f -N -M -S "$control" -o BatchMode=yes -o ExitOnForwardFailure=yes \
  -L "$local_port:127.0.0.1:$((5900 + display))" "$target"
cleanup() {
  remote "pkill -f '^mousepad $work'; pkill -f '^xfce4-terminal --disable-server --title=vnc-shortcuts'; rm -rf $work" \
    >/dev/null 2>&1 || true
  ssh -S "$control" -O exit "$target" >/dev/null 2>&1 || true
}
trap cleanup EXIT
remote 'command -v mousepad >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -q mousepad >/dev/null'

text="codevisor shortcuts $nonce"
remote "$session; mkdir -p $work; printf '%s' '$text' > $work/note.txt; setsid mousepad $work/note.txt >/dev/null 2>&1 < /dev/null &"
wid=$(remote "timeout 20 xdotool search --sync --onlyvisible --name 'note.txt - Mousepad' | tail -1")
[[ -n "$wid" ]] || { echo "✘ Mousepad's window never appeared" >&2; exit 1; }
remote "xdotool windowactivate --sync $wid"; sleep 1
remote 'printf "before" | xclip -i -selection clipboard >/dev/null 2>&1'
keys cmd+a cmd+c; sleep 0.5
check "⌘A ⌘C in Mousepad copies the text" "$(clipboard)" "$text"
keys cmd+end return cmd+v cmd+s; sleep 1
check "⌘V ⌘S in Mousepad pastes and saves" "$(remote "cat $work/note.txt")" "$text
$text"

remote "$session; setsid xfce4-terminal --disable-server --title=vnc-shortcuts --geometry 70x8+120+120 -x bash -c 'echo marker-$nonce; read -r line; printf %s \"\$line\" > $work/pasted.txt; sleep 30' >/dev/null 2>&1 < /dev/null &"
tid=$(remote "timeout 20 xdotool search --sync --name '^vnc-shortcuts\$' | head -1")
[[ -n "$tid" ]] || { echo "✘ the terminal's window never appeared" >&2; exit 1; }
remote "xdotool windowactivate --sync $tid"; sleep 1
remote "printf 'pasted-$nonce' | xclip -i -selection clipboard >/dev/null 2>&1"
keys cmd+shift+v return; sleep 1
check "⌘⇧V in the terminal pastes" "$(remote "cat $work/pasted.txt 2>/dev/null")" "pasted-$nonce"
keys cmd+shift+a cmd+shift+c; sleep 0.5
copied=$(clipboard)
[[ "$copied" == *"marker-$nonce"* ]] && copied="contains marker-$nonce"
check "⌘⇧A ⌘⇧C in the terminal copies its text" "$copied" "contains marker-$nonce"

[[ $failures == 0 ]] && echo "vnc-desktop-shortcuts: PASS" || { echo "vnc-desktop-shortcuts: FAIL ($failures)"; exit 1; }

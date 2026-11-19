#!/usr/bin/env bash
set -euo pipefail

usage="Usage: $0 [--fresh-data] [output directory]"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

fresh_data=""
out="tmp/tab-switch-bench"
for argument in "$@"; do
  case "$argument" in
    --fresh-data) fresh_data=1 ;;
    -*) echo "$usage" >&2; exit 2 ;;
    *) out="$argument" ;;
  esac
done
mkdir -p "$out"
log="$out/dev.log"
runner=""
server=""

stop_app() {
  local waited=0
  [[ -n "$runner" ]] || return 0
  kill "$runner" 2>/dev/null || true
  wait "$runner" 2>/dev/null || true
  runner=""
  while [[ -n "$(pgrep -f "$root/scripts/dev-owner.mjs" || true)" ]] && ((waited < 90)); do
    sleep 1
    waited=$((waited + 1))
  done
}
trap stop_app EXIT
trap "exit 130" INT HUP TERM

app_connected() {
  server="$(sed -n 's/.*dev server is listening on \(http[^ ]*\).*/\1/p' "$log" | tail -1)"
  [[ -n "$server" ]] && curl -fsS -m 3 "$server/v1/clients" 2>/dev/null | grep -q macos
}

start_app() {
  local waited=0
  TRANSCRIPT_STRESS=1 bun run dev:macos --no-containers "$@" >"$log" 2>&1 &
  runner=$!
  until app_connected; do
    if ! kill -0 "$runner" 2>/dev/null || ((waited > 1200)); then
      echo "The dev app did not come up. The end of its log:" >&2
      tail -n 60 "$log" >&2
      exit 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

if ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -q "<true/>"; then
  echo "This Mac's screen is locked, so no window is drawn and a switch does no real work. Unlock it and run again." >&2
  exit 1
fi

if [[ -n "$fresh_data" ]]; then
  rm -rf tmp/.codevisor
  start_app
  stop_app
  start_app --reuse-macos-build
else
  start_app
fi

settle() {
  local waited=0
  until awk '{ exit !($2 < 4) }' <<<"$(sysctl -n vm.loadavg)"; do
    if ((waited >= 180)); then return 1; fi
    sleep 10
    waited=$((waited + 10))
  done
}

app="$(find tmp/build/macos/DerivedData/Build/Products/Debug -maxdepth 1 -name "*.app" | head -1)"
quiet=1
settle || quiet=""
open "$app"
sleep 10

options=()
if [[ -n "${TAB_SWITCH_LIMITS:-}" ]]; then options+=(--limits "$TAB_SWITCH_LIMITS"); fi
if [[ -n "${TAB_SWITCH_ENFORCE:-}" && -n "$quiet" ]]; then options+=(--enforce); fi
{
  echo "Load before the run: $(sysctl -n vm.loadavg)"
  if [[ -z "$quiet" ]]; then echo "The Mac was still busy after three minutes, so the limits are reported but not enforced."; fi
} | tee "$out/load.txt"
TRANSCRIPT_STRESS_URL="$server" node scripts/dev-tab-switch-bench.mjs --fresh --chats 8 --turns 200 \
  ${options[@]+"${options[@]}"} --report "$out/report.md" | tee "$out/summary.json"

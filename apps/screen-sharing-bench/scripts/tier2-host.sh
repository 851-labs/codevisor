#!/usr/bin/env bash
set -euo pipefail

results=${1:-}
[[ -n "$results" ]] || { echo "Usage: $0 <results-directory>" >&2; exit 2; }
source "$(dirname "${BASH_SOURCE[0]}")/tier2-lib.sh"
mkdir -p "$results"
work="$(mktemp -d /tmp/codevisor-tier2.XXXXXX)"
host_processes=screensharingd,ScreensharingAgent,CodevisorBench:share,VTEncoderXPCService,replayd,WindowServer
background=()
stop_background() {
  for pid in ${background[@]+"${background[@]}"}; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$work"
}
trap stop_background EXIT

viewer_addresses() {
  echo "$TIER2_VIEWER_IP,$TIER2_VIEWER_NAME"
}

start_share() {
  local dir=$1 system=$2
  local virtual=()
  [[ "$system" == codevisor-r1x2 ]] && virtual=(--virtual-display R1x2)
  bench share --duration "$((TIER2_DURATION + 240))" --ready-file "$work/ready" --stop-file "$work/stop" \
    ${virtual[@]+"${virtual[@]}"} >"$dir/share.json" 2>"$dir/share.err" &
  share_job=$!
  wait_for_file "$work/ready" 30 "$share_job" || return 1
  shared_display=$(awk '{ print $3 }' "$work/ready")
  [[ "$system" != codevisor-r1x2 || "$shared_display" =~ ^[0-9]+$ ]] || {
    say "share named no display"
    stop_share
    return 1
  }
}


measure() {
  local scene=$1 system=$2 dir=$3 observed=$4
  local pids=() display=() player_display=()
  if [[ "$system" == codevisor-r1x2 ]]; then
    display=(--display "$shared_display")
    player_display=(--display-id "$shared_display")
  fi
  if ((observed)); then
    local relay=()
    [[ "$system" == floor ]] && relay=(--relay "$TIER2_VIEWER_IP:$TIER2_FLOOR_PORT")
    bench observe --duration "$((TIER2_DURATION + 12))" --output "$dir/host.jsonl" ${relay[@]+"${relay[@]}"} \
      ${display[@]+"${display[@]}"} \
      >"$dir/host-observe.json" 2>"$dir/host-observe.err" &
    pids+=($!)
  fi
  bench sample --duration "$((TIER2_DURATION + 10))" --interface en0 --processes "$host_processes" \
    --output "$dir/host-usage.jsonl" >"$dir/host-sample.json" 2>"$dir/host-sample.err" &
  pids+=($!)
  sleep 3
  bench_window player --scene "$scene" --seed "$TIER2_SEED" --duration "$((TIER2_DURATION + 6))" \
    ${player_display[@]+"${player_display[@]}"} \
    >"$dir/player.json" 2>"$dir/player.err" &
  pids+=($!)
  local failed=0
  for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
  return "$failed"
}

stop_share() {
  touch "$work/stop"
  if [[ -n "${share_job:-}" ]]; then wait "$share_job" || true; fi
  share_job="" shared_display=""
}

run_one() {
  local index=$1 scene=$2 system=$3 rep=$4 observed=$5
  local name dir status=ok
  name=$(tier2_name "$@")
  dir="$results/$name"
  mkdir -p "$dir"
  rm -f "$work/ready" "$work/stop"
  share_job=""
  preflight "$dir/host-before-preflight.json" --allow-screen-sharing-from "$(viewer_addresses)" || status="host preflight failed"
  meet host "$name-start" "$status" || return 0
  if [[ "$system" == codevisor* ]] && ! start_share "$dir" "$system"; then status="share did not start"; fi
  meet host "$name-system" "$status" || { stop_share; return 0; }
  meet host "$name-ready" || { stop_share; return 0; }
  preflight "$dir/host-during-preflight.json" --allow-screen-sharing-from "$(viewer_addresses)" || status="host preflight failed"
  meet host "$name-measure" "$status" || { stop_share; return 0; }
  say "measuring $name"
  measure "$scene" "$system" "$dir" "$observed" || say "a host measurement process failed in $name"
  meet host "$name-done" || true
  stop_share
  preflight "$dir/host-after-preflight.json" --allow-screen-sharing-from "$(viewer_addresses)" || true
}

tier2_check_inputs
"$tier2_scripts/record-installed-commit.sh" "$results"
commit=$(cat "$results/installed-commit.txt")
bench calibrate --check c2 --serve --duration 3600 --idle-exit "$TIER2_RENDEZVOUS_S" \
  >"$results/responder.json" 2>"$results/responder.err" &
background+=($!)
bench rendezvous --serve --duration 3600 >"$results/rendezvous.json" 2>"$results/rendezvous.err" &
background+=($!)
meet_on_build host "$commit"
while read -r index scene system rep observed; do
  run_one "$index" "$scene" "$system" "$rep" "$observed"
done < <(tier2_plan)

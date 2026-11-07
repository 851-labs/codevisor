#!/usr/bin/env bash
set -euo pipefail

results=${1:-}
[[ -n "$results" ]] || { echo "Usage: $0 <results-directory>" >&2; exit 2; }
source "$(dirname "${BASH_SOURCE[0]}")/tier2-lib.sh"
mkdir -p "$results"
work="$(mktemp -d /tmp/codevisor-tier2.XXXXXX)"
rendezvous_port=47595
host_processes=screensharingd,ScreensharingAgent,avconferenced,CodevisorBench:share,VTEncoderXPCService,replayd,WindowServer
profiled_processes=(avconferenced ScreensharingAgent VTEncoderXPCService replayd)
profile_lead_s=20
profile_s=10
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
  tier2_on_virtual_display "$system" && virtual=(--virtual-display R1x2)
  bench share --duration "$((TIER2_DURATION + 240))" --ready-file "$work/ready" --stop-file "$work/stop" \
    $(tier2_encoder_options "$system") ${virtual[@]+"${virtual[@]}"} >"$dir/share.json" 2>"$dir/share.err" &
  share_job=$!
  wait_for_file "$work/ready" 30 "$share_job" || return 1
  shared_display=$(awk '{ print $3 }' "$work/ready")
  ! tier2_on_virtual_display "$system" || [[ "$shared_display" =~ ^[0-9]+$ ]] || {
    say "share named no display"
    stop_share
    return 1
  }
}

profile() {
  local system=$1 dir=$2 name pid targets=() target
  sleep "$profile_lead_s"
  for name in "${profiled_processes[@]}"; do
    for pid in $(pgrep -x "$name"); do targets+=("$name-$pid:$pid"); done
  done
  if [[ "$system" == codevisor* ]]; then
    for pid in $(pgrep -U "$(id -u)" -f "CodevisorBench.app/Contents/MacOS/CodevisorBench share"); do
      targets+=("share-$pid:$pid")
    done
  fi
  for target in ${targets[@]+"${targets[@]}"}; do
    sample "${target#*:}" "$profile_s" -mayDie -file "$dir/profile-${target%%:*}.txt" >/dev/null 2>>"$dir/profile.err" &
  done
  wait
}

measure() {
  local scene=$1 system=$2 dir=$3 observed=$4
  local pids=() display=() player_display=()
  if tier2_is_local_input_floor "$scene" "$system"; then
    say "the input floor runs on the viewer; nothing to host"
    return 0
  fi
  if tier2_on_virtual_display "$system"; then
    display=(--display "$shared_display")
    player_display=(--display-id "$shared_display")
  fi
  if ((observed)); then
    local relay=()
    [[ "$system" == floor ]] && relay=(--relay "$TIER2_VIEWER_IP:$TIER2_FLOOR_PORT")
    bench observe --duration "$((TIER2_DURATION + 12))" --output "$dir/host.jsonl" ${relay[@]+"${relay[@]}"} \
      ${display[@]+"${display[@]}"} $(tier2_stills_options "$scene" "$system" "$dir/host-stills") \
      >"$dir/host-observe.json" 2>"$dir/host-observe.err" &
    pids+=($!)
    if tier2_has_bottom_barcode "$scene" "$system"; then
      bench observe --duration "$((TIER2_DURATION + 12))" --output "$dir/host-bottom.jsonl" --barcode-anchor bottom \
        ${display[@]+"${display[@]}"} >"$dir/host-bottom-observe.json" 2>"$dir/host-bottom-observe.err" &
      pids+=($!)
    fi
  fi
  bench sample --duration "$((TIER2_DURATION + 10))" --interface en0 --processes "$host_processes" \
    --output "$dir/host-usage.jsonl" >"$dir/host-sample.json" 2>"$dir/host-sample.err" &
  pids+=($!)
  if sudo -n -l /usr/bin/powermetrics >/dev/null 2>&1; then
    { sudo -n /usr/bin/powermetrics --samplers cpu_power,gpu_power -i 1000 -n "$((TIER2_DURATION + 8))" \
      >"$dir/host-power.txt" 2>"$dir/host-power.err" || true; } &
    pids+=($!)
  fi
  if ((TIER2_PROFILE)); then
    profile "$system" "$dir" &
    pids+=($!)
  fi
  sleep 3
  local bottom=()
  tier2_has_bottom_barcode "$scene" "$system" && bottom=(--bottom-barcode)
  bench_window player --scene "$scene" --seed "$TIER2_SEED" --duration "$((TIER2_DURATION + 6))" \
    ${player_display[@]+"${player_display[@]}"} ${bottom[@]+"${bottom[@]}"} \
    >"$dir/player.json" 2>"$dir/player.err" &
  pids+=($!)
  local failed=0
  for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
  return "$failed"
}

stop_stale_servers() {
  local pid
  for pid in $(pgrep -U "$(id -u)" -f "CodevisorBench (rendezvous|calibrate --check c2) --serve"); do
    if [[ "$(ps -p "$pid" -o comm=)" == */CodevisorBench.app/Contents/MacOS/CodevisorBench ]]; then
      kill "$pid" 2>/dev/null || true
    fi
  done
}

await_servers() {
  local deadline=$((SECONDS + 30))
  until lsof -nP -iTCP:"$rendezvous_port" -sTCP:LISTEN >/dev/null && lsof -nP -iUDP:"$TIER2_CLOCK_PORT" >/dev/null &&
    lsof -nP -iUDP:"$TIER2_NETWORK_CHECK_PORT" >/dev/null; do
    for pid in "${background[@]}"; do kill -0 "$pid" 2>/dev/null || return 1; done
    ((SECONDS < deadline)) || return 1
    sleep 0.5
  done
}

stop_share() {
  touch "$work/stop"
  if [[ -n "${share_job:-}" ]]; then wait "$share_job" || true; fi
  share_job="" shared_display=""
}

run_one() {
  local index=$1 scene=$2 system=$3 rep=$4 observed=$5 network=$6
  local name dir status=ok
  tier2_is_warm_up "$rep" && local TIER2_DURATION=$TIER2_WARM_UP_S
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
ready=$(tier2_ready_status "$results" host "$commit")
stop_stale_servers
bench calibrate --check c2 --serve --duration 3600 --idle-exit "$TIER2_RENDEZVOUS_S" \
  >"$results/responder.json" 2>"$results/responder.err" &
background+=($!)
bench rendezvous --serve --duration 3600 >"$results/rendezvous.json" 2>"$results/rendezvous.err" &
background+=($!)
bench calibrate --check c2 --serve --port "$TIER2_NETWORK_CHECK_PORT" --duration 3600 \
  --idle-exit "$TIER2_RENDEZVOUS_S" >"$results/network-responder.json" 2>"$results/network-responder.err" &
background+=($!)
await_servers || { say "the clock responder or rendezvous server didn't start"; exit 1; }
meet_on_build host "$ready"
while read -r index scene system rep observed network; do
  run_one "$index" "$scene" "$system" "$rep" "$observed" "$network"
done < <(tier2_plan)

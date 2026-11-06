#!/usr/bin/env bash
set -euo pipefail

results=${1:-}
[[ -n "$results" ]] || { echo "Usage: $0 <results-directory>" >&2; exit 2; }
source "$(dirname "${BASH_SOURCE[0]}")/tier2-lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/tier2-network.sh"
mkdir -p "$results"
work="$(mktemp -d /tmp/codevisor-tier2.XXXXXX)"
viewer_processes="Screen Sharing,avconferenced,CodevisorBench:view,VTDecoderXPCService"
trap 'network_reset; rm -rf "$work"' EXIT

start_system() {
  local system=$1 dir=$2 scene=$3
  local seconds=$((TIER2_DURATION + 240))
  local signals=(--duration "$seconds" --ready-file "$work/ready" --stop-file "$work/stop" $(tier2_viewer_display_options))
  local control=()
  [[ "$scene" == input ]] && control=(--control)
  if tier2_is_local_input_floor "$scene" "$system"; then
    touch "$work/ready"
    viewer_display_id=""
    return 0
  fi
  case "$system" in
    apple-hp) bench apple-hp --host "$TIER2_APPLE_HOST" ${control[@]+"${control[@]}"} "${signals[@]}" \
      >"$dir/system.json" 2>"$dir/system.err" & ;;
    codevisor-v2 | codevisor-v2-vcp) bench_window view --source codevisor --host "$TIER2_HOST_IP" \
      --present "$TIER2_PRESENT" ${control[@]+"${control[@]}"} "${signals[@]}" >"$dir/system.json" 2>"$dir/system.err" & ;;
    floor) bench_window view --source null --port "$TIER2_FLOOR_PORT" "${signals[@]}" >"$dir/system.json" 2>"$dir/system.err" & ;;
  esac
  system_job=$!
  wait_for_file "$work/ready" 60 "$system_job" || return 1
  viewer_display_id=$(awk '{ print $NF }' "$work/ready")
  [[ "$TIER2_VIEWER_DISPLAY" == main || "$viewer_display_id" =~ ^[0-9]+$ ]] || { say "$system named no display"; return 1; }
}

stop_system() {
  touch "$work/stop"
  if [[ -n "${system_job:-}" ]]; then wait "$system_job" || true; fi
  system_job=""
  pkill -x "Screen Sharing" || true
}

start_input() {
  local dir=$1 system=$2 scene=$3
  [[ "$scene" == input ]] || return 0
  if tier2_is_local_input_floor "$scene" "$system"; then
    bench_window player --scene input --seed "$TIER2_SEED" --duration "$((TIER2_DURATION + 6))" \
      >"$dir/player.json" 2>"$dir/player.err" &
    pids+=($!)
  fi
  bench inject --keys "$TIER2_INPUT_EVENTS" --clicks "$TIER2_INPUT_EVENTS" --seed "$TIER2_SEED" \
    --start-delay "$tier2_input_lead_s" --duration "$(tier2_input_window_s)" --output "$dir/input-events.jsonl" \
    ${display[@]+"${display[@]}"} >"$dir/inject.json" 2>"$dir/inject.err" &
  pids+=($!)
}

measure() {
  local dir=$1 system=$2 scene=$3
  local pids=() display=()
  [[ "$TIER2_VIEWER_DISPLAY" == main || -z "${viewer_display_id:-}" ]] || display=(--display "$viewer_display_id")
  bench calibrate --check c2 --responder "$TIER2_HOST_IP" --duration "$((TIER2_DURATION + 18))" \
    --output "$dir/clock.jsonl" >"$dir/clock.json" 2>"$dir/clock.err" &
  pids+=($!)
  bench observe --duration "$((TIER2_DURATION + 14))" --output "$dir/viewer.jsonl" \
    --block-size "$(tier2_viewer_block_size "$system")" ${display[@]+"${display[@]}"} \
    $(tier2_stills_options "$scene" "$system" "$dir/viewer-stills") \
    >"$dir/viewer-observe.json" 2>"$dir/viewer-observe.err" &
  pids+=($!)
  if tier2_has_bottom_barcode "$scene" "$system"; then
    bench observe --duration "$((TIER2_DURATION + 14))" --output "$dir/viewer-bottom.jsonl" --barcode-anchor bottom \
      --block-size "$(tier2_viewer_block_size "$system")" ${display[@]+"${display[@]}"} \
      >"$dir/viewer-bottom-observe.json" 2>"$dir/viewer-bottom-observe.err" &
    pids+=($!)
  fi
  bench sample --duration "$((TIER2_DURATION + 10))" --interface en0 --processes "$viewer_processes" \
    --output "$dir/viewer-usage.jsonl" >"$dir/viewer-sample.json" 2>"$dir/viewer-sample.err" &
  pids+=($!)
  start_input "$dir" "$system" "$scene"
  local failed=0
  for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
  return "$failed"
}

write_meta() {
  local dir=$1 index=$2 scene=$3 system=$4 rep=$5 observed=$6 network=$7 started_at=$8
  local observed_json=false
  ((observed)) && observed_json=true
  cat >"$dir/meta.json" <<JSON
{"index": $index, "scene": "$scene", "system": "$system", "resolution": "$(tier2_resolution "$system")",
 "network": "$network", "viewer_display": "$TIER2_VIEWER_DISPLAY", "presentation": "$TIER2_PRESENT",
 "repetition": $rep, "seed": $TIER2_SEED,
 "duration_s": $TIER2_DURATION, "host_observer": $observed_json, "git_sha": "$commit", "started_at": "$started_at",
 "github_run_id": "${GITHUB_RUN_ID:-}"}
JSON
}

shape() {
  local network=$1
  [[ "$network" == "$shaped_network" ]] && return 0
  shaped_network=""
  network_apply "$network" || return 1
  shaped_network=$network
}

run_one() {
  local index=$1 scene=$2 system=$3 rep=$4 observed=$5 network=$6
  local name dir started_at status=ok
  if tier2_is_warm_up "$rep"; then
    local TIER2_DURATION=$TIER2_WARM_UP_S
    local TIER2_INPUT_EVENTS
    TIER2_INPUT_EVENTS=$(tier2_warm_up_input_events)
  fi
  name=$(tier2_name "$@")
  dir="$results/$name"
  mkdir -p "$dir"
  rm -f "$work/ready" "$work/stop"
  started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  shape "$network" || status="$network shaping didn't load"
  [[ "$status" != ok ]] || preflight "$dir/viewer-before-preflight.json" || status="viewer preflight failed"
  meet viewer "$name-start" "$status" || { say "skipping $name: not ready at start"; return 0; }
  meet viewer "$name-system" || { say "skipping $name: the host could not start"; return 0; }
  start_system "$system" "$dir" "$scene" || status="$system did not become ready"
  meet viewer "$name-ready" "$status" || { say "skipping $name: $status"; stop_system; return 0; }
  [[ "$network" == N0 ]] || network_check "$dir"
  meet viewer "$name-measure" || { say "skipping $name: host preflight failed"; stop_system; return 0; }
  say "measuring $name"
  measure "$dir" "$system" "$scene" || say "a viewer measurement process failed in $name"
  meet viewer "$name-done" || true
  stop_system
  preflight "$dir/viewer-after-preflight.json" || true
  tier2_is_warm_up "$rep" && return 0
  write_meta "$dir" "$index" "$scene" "$system" "$rep" "$observed" "$network" "$started_at"
}

tier2_check_inputs
"$tier2_scripts/record-installed-commit.sh" "$results"
commit=$(cat "$results/installed-commit.txt")
shaped_network=""
network_reset
meet_on_build viewer "$(tier2_ready_status "$results" viewer "$commit")"
while read -r index scene system rep observed network; do
  run_one "$index" "$scene" "$system" "$rep" "$observed" "$network"
done < <(tier2_plan)

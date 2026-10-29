#!/usr/bin/env bash
set -euo pipefail

results=${1:-}
[[ -n "$results" ]] || { echo "Usage: $0 <results-directory>" >&2; exit 2; }
source "$(dirname "${BASH_SOURCE[0]}")/tier2-lib.sh"
mkdir -p "$results"
work="$(mktemp -d /tmp/codevisor-tier2.XXXXXX)"
viewer_processes="Screen Sharing,CodevisorBench:view,VTDecoderXPCService"
trap 'rm -rf "$work"' EXIT

start_system() {
  local system=$1 dir=$2
  local seconds=$((TIER2_DURATION + 240))
  local signals=(--duration "$seconds" --ready-file "$work/ready" --stop-file "$work/stop")
  case "$system" in
    apple-hp) bench apple-hp --host "$TIER2_APPLE_HOST" "${signals[@]}" >"$dir/system.json" 2>"$dir/system.err" & ;;
    codevisor | codevisor-r1x2) bench_window view --source codevisor --host "$TIER2_HOST_IP" "${signals[@]}" >"$dir/system.json" 2>"$dir/system.err" & ;;
    floor) bench_window view --source null --port "$TIER2_FLOOR_PORT" "${signals[@]}" >"$dir/system.json" 2>"$dir/system.err" & ;;
  esac
  system_job=$!
  wait_for_file "$work/ready" 60 "$system_job"
}

stop_system() {
  touch "$work/stop"
  if [[ -n "${system_job:-}" ]]; then wait "$system_job" || true; fi
  system_job=""
  pkill -x "Screen Sharing" || true
}

measure() {
  local dir=$1 system=$2
  local pids=()
  bench calibrate --check c2 --responder "$TIER2_HOST_IP" --duration "$((TIER2_DURATION + 18))" \
    --output "$dir/clock.jsonl" >"$dir/clock.json" 2>"$dir/clock.err" &
  pids+=($!)
  bench observe --duration "$((TIER2_DURATION + 14))" --output "$dir/viewer.jsonl" \
    --block-size "$(tier2_viewer_block_size "$system")" \
    >"$dir/viewer-observe.json" 2>"$dir/viewer-observe.err" &
  pids+=($!)
  bench sample --duration "$((TIER2_DURATION + 10))" --interface en0 --processes "$viewer_processes" \
    --output "$dir/viewer-usage.jsonl" >"$dir/viewer-sample.json" 2>"$dir/viewer-sample.err" &
  pids+=($!)
  local failed=0
  for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
  return "$failed"
}

write_meta() {
  local dir=$1 index=$2 scene=$3 system=$4 rep=$5 observed=$6 started_at=$7
  local observed_json=false
  ((observed)) && observed_json=true
  cat >"$dir/meta.json" <<JSON
{"index": $index, "scene": "$scene", "system": "${system%-r1x2}", "resolution": "$(tier2_resolution "$system")",
 "repetition": $rep, "seed": $TIER2_SEED,
 "duration_s": $TIER2_DURATION, "host_observer": $observed_json, "git_sha": "$commit", "started_at": "$started_at",
 "github_run_id": "${GITHUB_RUN_ID:-}"}
JSON
}

run_one() {
  local index=$1 scene=$2 system=$3 rep=$4 observed=$5
  local name dir started_at status=ok
  name=$(tier2_name "$@")
  dir="$results/$name"
  mkdir -p "$dir"
  rm -f "$work/ready" "$work/stop"
  started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  preflight "$dir/viewer-before-preflight.json" || status="viewer preflight failed"
  meet viewer "$name-start" "$status" || { say "skipping $name: not ready at start"; return 0; }
  meet viewer "$name-system" || { say "skipping $name: the host could not start"; return 0; }
  start_system "$system" "$dir" || status="$system did not become ready"
  meet viewer "$name-ready" "$status" || { say "skipping $name: $status"; stop_system; return 0; }
  meet viewer "$name-measure" || { say "skipping $name: host preflight failed"; stop_system; return 0; }
  say "measuring $name"
  measure "$dir" "$system" || say "a viewer measurement process failed in $name"
  meet viewer "$name-done" || true
  stop_system
  preflight "$dir/viewer-after-preflight.json" || true
  write_meta "$dir" "$index" "$scene" "$system" "$rep" "$observed" "$started_at"
}

tier2_check_inputs
"$tier2_scripts/record-installed-commit.sh" "$results"
commit=$(cat "$results/installed-commit.txt")
meet_on_build viewer "$commit"
while read -r index scene system rep observed; do
  run_one "$index" "$scene" "$system" "$rep" "$observed"
done < <(tier2_plan)

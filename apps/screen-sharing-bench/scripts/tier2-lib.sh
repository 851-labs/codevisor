#!/usr/bin/env bash

: "${TIER2_HOST_IP:=192.168.10.78}"
: "${TIER2_VIEWER_IP:=192.168.10.103}"
: "${TIER2_VIEWER_NAME:=croissants-Mac-Mini.local}"
: "${TIER2_APPLE_HOST:=tamales-Mac-Mini.local}"
: "${TIER2_SCENES:=scroll}"
: "${TIER2_REPS:=3}"
: "${TIER2_DURATION:=60}"
: "${TIER2_FLOOR_REPS:=1}"
: "${TIER2_C4:=1}"
: "${TIER2_RENDEZVOUS_S:=1800}"

tier2_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tier2_run_overhead_s=90
tier2_settle_limit_s=600
tier2_abort_wait_s=120
tier2_plan_budget_s=2700
: "${TIER2_FLOOR_PORT:=47594}"
: "${TIER2_SEED:=1}"

bench() {
  CODEVISOR_BENCH_BACKGROUND=1 "$tier2_scripts/run-installed.sh" "$@"
}

bench_window() {
  "$tier2_scripts/run-installed.sh" "$@"
}

say() {
  echo "$(date '+%H:%M:%S') $*" >&2
}

tier2_plan() {
  local index=0 scene rep scenes
  IFS=, read -r -a scenes <<<"$TIER2_SCENES"
  for scene in "${scenes[@]}"; do
    for ((rep = 1; rep <= TIER2_FLOOR_REPS; rep++)); do
      index=$((index + 1)); echo "$index $scene floor $rep 1"
    done
    for ((rep = 1; rep <= TIER2_REPS; rep++)); do
      index=$((index + 1)); echo "$index $scene apple-hp $rep 1"
      index=$((index + 1)); echo "$index $scene codevisor-r1x2 $rep 1"
      index=$((index + 1)); echo "$index $scene codevisor $rep 1"
    done
  done
  if ((TIER2_C4)) && [[ ",$TIER2_SCENES," == *,video,* ]]; then
    index=$((index + 1)); echo "$index video apple-hp 1 0"
    index=$((index + 1)); echo "$index video codevisor-r1x2 1 0"
  fi
}

tier2_name() {
  local index=$1 scene=$2 system=$3 rep=$4 observed=$5
  local name
  name=$(printf '%02d-%s-%s-%d' "$index" "$scene" "$system" "$rep")
  ((observed)) || name="$name-unobserved"
  echo "$name"
}

tier2_resolution() {
  case "$1" in
    apple-hp | codevisor-r1x2) echo R1x2 ;;
    *) echo R1 ;;
  esac
}

tier2_viewer_block_size() {
  case "$(tier2_resolution "$1")" in
    R1x2) echo 8 ;;
    *) echo 16 ;;
  esac
}

meet() {
  local party=$1 barrier=$2 status=${3:-ok} timeout=${4:-$((TIER2_DURATION + 300))}
  bench rendezvous --host "$TIER2_HOST_IP" --party "$party" --barrier "$barrier" --status "$status" \
    --duration "$timeout" >/dev/null
}

tier2_ready_status() {
  local results=$1 role=$2 commit=$3
  if preflight "$results/$role-quiet-preflight.json" --quiet --settle-limit "$tier2_settle_limit_s"; then
    echo "$commit"
  else
    echo "abort: $role preflight failed (see $role-quiet-preflight.json)"
  fi
}

meet_on_build() {
  local party=$1 status=$2
  local wait_s=$TIER2_RENDEZVOUS_S
  [[ "$status" == abort:* ]] && wait_s=$tier2_abort_wait_s
  bench rendezvous --host "$TIER2_HOST_IP" --party "$party" --barrier hello --status "$status" --agree \
    --duration "$wait_s" >&2 || {
    say "not starting: the Macs aren't both quiet and on the same build (their hello statuses are above)"
    return 1
  }
}

tier2_check_inputs() {
  local scene_pattern="(idle-cursor|typing|scroll|window-drag|video|test-cards)"
  [[ "$TIER2_SCENES" =~ ^$scene_pattern(,$scene_pattern)*$ ]] || { echo "unknown scene in $TIER2_SCENES" >&2; return 1; }
  [[ "$TIER2_REPS" =~ ^[1-4]$ && "$TIER2_FLOOR_REPS" =~ ^[0-3]$ && "$TIER2_DURATION" =~ ^[0-9]+$ ]] || return 1
  ((TIER2_DURATION >= 15 && TIER2_DURATION <= 120)) || return 1
  local runs
  runs=$(($(tier2_plan | wc -l)))
  ((runs * (TIER2_DURATION + tier2_run_overhead_s) <= tier2_plan_budget_s)) || {
    echo "$runs runs of ${TIER2_DURATION}s don't fit the ${tier2_plan_budget_s}s budget" >&2
    return 1
  }
}

preflight() {
  local file=$1
  shift
  bench preflight "$@" >"$file"
}

wait_for_file() {
  local path=$1 timeout_s=$2 job=$3
  local deadline=$((SECONDS + timeout_s))
  until [[ -f "$path" ]]; do
    kill -0 "$job" 2>/dev/null || return 1
    ((SECONDS < deadline)) || return 1
    sleep 0.5
  done
}


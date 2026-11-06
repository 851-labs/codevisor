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
: "${TIER2_NETWORK:=N0}"
: "${TIER2_PRESENT:=arrival}"
: "${TIER2_SYSTEMS:=apple-hp,codevisor-v2-vcp}"
: "${TIER2_VIEWER_DISPLAY:=main}"
: "${TIER2_VCP_FAIL_AFTER:=0}"

tier2_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tier2_run_overhead_s=30
tier2_settle_limit_s=600
tier2_abort_wait_s=120
tier2_plan_budget_s=1800
tier2_first_still_version=4
tier2_last_still_version=11
: "${TIER2_FLOOR_PORT:=47594}"
: "${TIER2_CLOCK_PORT:=47592}"
: "${TIER2_NETWORK_CHECK_PORT:=47596}"
: "${TIER2_SEED:=1}"
: "${TIER2_INPUT_EVENTS:=200}"
: "${TIER2_PROFILE:=0}"
: "${TIER2_WARM_UP_S:=30}"
tier2_input_lead_s=8
tier2_input_budget_ms_per_event=263

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
  local index=0 token scene network rep tokens warm_up=0
  IFS=, read -r -a tokens <<<"$TIER2_SCENES"
  ((TIER2_WARM_UP_S > 0)) && tier2_runs_system apple-hp && warm_up=1
  for token in "${tokens[@]}"; do
    scene=$(tier2_token_scene "$token") network=$(tier2_token_network "$token")
    for ((rep = 1; rep <= TIER2_FLOOR_REPS; rep++)); do
      index=$((index + 1)); echo "$index $scene floor $rep 1 $network"
    done
    if ((warm_up)); then
      index=$((index + 1)); echo "$index $scene apple-hp 0 0 $network"
      warm_up=0
    fi
    for ((rep = 1; rep <= TIER2_REPS; rep++)); do
      for system in apple-hp codevisor-v2 codevisor-v2-vcp; do
        tier2_runs_system "$system" || continue
        index=$((index + 1)); echo "$index $scene $system $rep 1 $network"
      done
    done
  done
  if ((TIER2_C4)) && [[ ",$TIER2_SCENES," == *,video,* ]]; then
    for system in apple-hp codevisor-v2 codevisor-v2-vcp; do
      tier2_runs_system "$system" || continue
      index=$((index + 1)); echo "$index video $system 1 0 $TIER2_NETWORK"
    done
  fi
}

tier2_token_scene() {
  echo "${1%@*}"
}

tier2_token_network() {
  if [[ "$1" == *@* ]]; then echo "${1#*@}"; else echo "$TIER2_NETWORK"; fi
}

tier2_scene_names() {
  local token tokens names=()
  IFS=, read -r -a tokens <<<"$TIER2_SCENES"
  for token in "${tokens[@]}"; do names+=("$(tier2_token_scene "$token")"); done
  local IFS=,
  echo "${names[*]}"
}

tier2_runs_system() {
  [[ ",$TIER2_SYSTEMS," == *",$1,"* ]]
}

tier2_encoder_options() {
  if [[ "$1" == codevisor-v2-vcp ]]; then
    echo --encoder vcp
    ((TIER2_VCP_FAIL_AFTER > 0)) && echo --vcp-fail-after "$TIER2_VCP_FAIL_AFTER"
  elif [[ "$1" == codevisor-v2 ]]; then
    echo --encoder vt
  fi
  return 0
}

tier2_on_virtual_display() {
  [[ "$1" == codevisor-v2 || "$1" == codevisor-v2-vcp ]]
}

tier2_is_warm_up() {
  (($1 == 0))
}

tier2_warm_up_input_events() {
  echo $(((TIER2_WARM_UP_S - tier2_input_lead_s) * 1000 / (2 * tier2_input_budget_ms_per_event)))
}

tier2_name() {
  local index=$1 scene=$2 system=$3 rep=$4 observed=$5 network=${6:-$TIER2_NETWORK}
  local name
  [[ "$network" == N0 ]] || scene="$scene-$network"
  if tier2_is_warm_up "$rep"; then
    printf '%02d-%s-%s-warm-up\n' "$index" "$scene" "$system"
    return
  fi
  name=$(printf '%02d-%s-%s-%d' "$index" "$scene" "$system" "$rep")
  ((observed)) || name="$name-unobserved"
  echo "$name"
}

tier2_resolution() {
  case "$1" in
    apple-hp | codevisor-v2 | codevisor-v2-vcp) echo R1x2 ;;
    *) echo R1 ;;
  esac
}

tier2_display_pixel_width() {
  case "$1" in
    R1x2) echo 3840 ;;
    *) echo 1920 ;;
  esac
}

tier2_viewer_block_size() {
  [[ "$1" == floor ]] && { echo 16; return; }
  local host viewer
  host=$(tier2_display_pixel_width "$(tier2_resolution "$1")")
  viewer=$(tier2_display_pixel_width "$TIER2_VIEWER_DISPLAY")
  echo $((16 * viewer / host))
}

tier2_viewer_display_options() {
  [[ "$TIER2_VIEWER_DISPLAY" == main ]] || echo --virtual-display "$TIER2_VIEWER_DISPLAY"
}

tier2_stills_versions() {
  local last=$((TIER2_DURATION / 3 - 2)) version versions=()
  ((last > tier2_last_still_version)) && last=$tier2_last_still_version
  for ((version = tier2_first_still_version; version <= last; version++)); do
    ((version % 4 == 3)) || versions+=("$version")
  done
  local IFS=,
  echo "${versions[*]}"
}

tier2_has_bottom_barcode() {
  [[ "$1" != test-cards && "$1" != input && "$2" != floor ]]
}

tier2_stills_options() {
  local scene=$1 system=$2 directory=$3 versions
  [[ "$scene" == test-cards && "$system" != floor ]] || return 0
  versions=$(tier2_stills_versions)
  [[ -n "$versions" ]] || return 0
  echo --region full --stills "$directory" --stills-versions "$versions"
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
  local scene_pattern="(idle-cursor|typing|scroll|window-drag|video|test-cards|input)(@N[036])?"
  [[ "$TIER2_SCENES" =~ ^$scene_pattern(,$scene_pattern)*$ ]] || {
    echo "unknown scene or network in $TIER2_SCENES (scenes are like scroll or scroll@N3)" >&2
    return 1
  }
  [[ "$TIER2_REPS" =~ ^[1-4]$ && "$TIER2_FLOOR_REPS" =~ ^[0-3]$ && "$TIER2_DURATION" =~ ^[0-9]+$ ]] || return 1
  ((TIER2_DURATION >= 15 && TIER2_DURATION <= 120)) || return 1
  [[ "$TIER2_NETWORK" =~ ^N[036]$ ]] || { echo "network must be N0, N3 or N6, not $TIER2_NETWORK" >&2; return 1; }
  [[ "$TIER2_VCP_FAIL_AFTER" =~ ^(0|[1-9][0-9]*)$ ]] && ((TIER2_VCP_FAIL_AFTER < TIER2_DURATION)) || {
    echo "vcp-fail-after must be whole seconds below the run's duration" >&2
    return 1
  }
  [[ "$TIER2_PRESENT" =~ ^(display-link|arrival)$ ]] || { echo "unknown presentation $TIER2_PRESENT" >&2; return 1; }
  tier2_check_input_scene || return 1
  [[ "$TIER2_VIEWER_DISPLAY" =~ ^(main|R1x2)$ ]] || { echo "viewer display must be main or R1x2" >&2; return 1; }
  [[ "$TIER2_PROFILE" =~ ^[01]$ ]] || { echo "profile must be 0 or 1, not $TIER2_PROFILE" >&2; return 1; }
  [[ "$TIER2_WARM_UP_S" =~ ^[0-9]+$ ]] && ((TIER2_WARM_UP_S == 0 || (TIER2_WARM_UP_S >= 20 && TIER2_WARM_UP_S <= 120))) || {
    echo "warm-up must be 0 (none) or 20 to 120 seconds, not $TIER2_WARM_UP_S" >&2
    return 1
  }
  local system_pattern="(apple-hp|codevisor-v2-vcp|codevisor-v2)"
  [[ "$TIER2_SYSTEMS" =~ ^$system_pattern(,$system_pattern)*$ ]] || { echo "unknown system in $TIER2_SYSTEMS" >&2; return 1; }
  local runs planned_s
  runs=$(($(tier2_plan | wc -l)))
  planned_s=$((runs * (TIER2_DURATION + tier2_run_overhead_s)))
  ((TIER2_WARM_UP_S > 0)) && tier2_runs_system apple-hp && planned_s=$((planned_s + TIER2_WARM_UP_S - TIER2_DURATION))
  ((planned_s <= tier2_plan_budget_s)) || {
    echo "$runs runs (${planned_s}s with overhead) don't fit the ${tier2_plan_budget_s}s budget" >&2
    return 1
  }
}

tier2_runs_input() {
  [[ ",$(tier2_scene_names)," == *,input,* ]]
}

tier2_input_window_s() {
  echo $((TIER2_DURATION - tier2_input_lead_s))
}

tier2_check_input_scene() {
  tier2_runs_input || return 0
  if ! [[ "$TIER2_INPUT_EVENTS" =~ ^[0-9]+$ ]] || ((TIER2_INPUT_EVENTS < 1 || TIER2_INPUT_EVENTS > 400)); then
    echo "input events must be 1 to 400 of each kind, not $TIER2_INPUT_EVENTS" >&2
    return 1
  fi
  if [[ "$TIER2_PRESENT" != arrival ]] && { tier2_runs_system codevisor-v2 || tier2_runs_system codevisor-v2-vcp; }; then
    echo "the input scene needs the arrival presentation" >&2
    return 1
  fi
  local needed_s=$(((2 * TIER2_INPUT_EVENTS * tier2_input_budget_ms_per_event + 999) / 1000))
  (($(tier2_input_window_s) >= needed_s)) || {
    echo "the input scene needs about ${needed_s}s after an ${tier2_input_lead_s}s lead; raise duration" >&2
    return 1
  }
}

tier2_is_local_input_floor() {
  [[ "$1" == input && "$2" == floor ]]
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


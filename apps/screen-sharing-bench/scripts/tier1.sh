#!/usr/bin/env bash
set -uo pipefail

mode=${1:-}
results=${2:-}
[[ ("$mode" == nightly || "$mode" == custom || "$mode" == gate) && -n "$results" ]] || {
  echo "Usage: $0 nightly|custom|gate <results-directory>" >&2
  exit 2
}
: "${TIER1_DURATION:=30}"
: "${TIER1_WARM_UP:=10}"
: "${TIER1_REPETITIONS:=3}"
: "${TIER1_SCENES:=}"
: "${TIER1_NETWORKS:=N0,N3}"
: "${TIER1_TRIGGER:=manual}"
: "${TIER1_SOURCE:=synthetic}"
core_networks=N0,N3
other_networks=N1,N2,N4,N5,N6,N7
gate_scenes=typing,scroll,video
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run_id="gha-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
mkdir -p "$results"

loopback() {
  local name=$1 repetitions=$2
  shift 2
  local started=$SECONDS
  "$scripts/run-installed.sh" loopback --run-id "$run_id-$name" --trigger "$TIER1_TRIGGER" \
    --output "$results/$name.json" --frames "$results/$name-frames.jsonl" --duration "$TIER1_DURATION" \
    --warm-up "$TIER1_WARM_UP" --repetitions "$repetitions" "$@" >/dev/null 2>"$results/$name.log"
  local status=$?
  echo "$name: $((SECONDS - started)) s, exit $status" >&2
  [[ -f "$results/$name.json" ]] && echo "$name" >>"$results/reports.txt"
  return "$status"
}

scenes() {
  [[ -z "$TIER1_SCENES" ]] || echo --scenes "$TIER1_SCENES"
}

nightly() {
  loopback core "$TIER1_REPETITIONS" --networks "$core_networks"
  local core=$?
  loopback matrix 1 --networks "$other_networks"
  return $((core || $?))
}

custom() {
  loopback custom "$TIER1_REPETITIONS" --networks "$TIER1_NETWORKS" --source "$TIER1_SOURCE" $(scenes)
}

gate() {
  local options=(--scenes "$gate_scenes" --networks "$core_networks")
  loopback first "$TIER1_REPETITIONS" "${options[@]}" && loopback second "$TIER1_REPETITIONS" "${options[@]}"
}

: >"$results/reports.txt"
"$scripts/record-installed-commit.sh" "$results"
uptime >"$results/load-before.txt"
"$mode"
status=$?
uptime >"$results/load-after.txt"
exit "$status"

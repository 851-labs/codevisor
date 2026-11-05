#!/usr/bin/env bash
set -uo pipefail

mode=${1:-}
results=${2:-}
[[ ("$mode" == nightly || "$mode" == custom || "$mode" == pr_gate) && -n "$results" ]] || {
  echo "Usage: $0 nightly|custom|pr_gate <results-directory>" >&2
  exit 2
}
: "${TIER1_DURATION:=30}"
: "${TIER1_WARM_UP:=10}"
: "${TIER1_REPETITIONS:=3}"
: "${TIER1_SCENES:=}"
: "${TIER1_NETWORKS:=N0,N3}"
: "${TIER1_TRIGGER:=manual}"
: "${TIER1_SOURCE:=synthetic}"
: "${TIER1_PLANS:=core-v2,gate-v2,matrix-v2}"
: "${TIER1_ENCODER:=vt}"
core_networks=N0,N3
other_networks=N1,N2,N4,N5,N6,N7
gate_options=(--scenes typing,scroll,video --networks N0,N3 --encoder vt)
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run_id="gha-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
mkdir -p "$results"

loopback() {
  local name=$1 plan=$2 repetitions=$3
  shift 3
  local started=$SECONDS
  "$scripts/run-installed.sh" loopback --run-id "$run_id-$name" --plan "$plan" --trigger "$TIER1_TRIGGER" \
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
  local status=0 plan
  for plan in core-v2 gate-v2 matrix-v2; do
    [[ ",$TIER1_PLANS," == *",$plan,"* ]] || continue
    "${plan/-v2/_v2}" || status=1
  done
  return "$status"
}

core_v2() {
  loopback core-v2 core-v2 "$TIER1_REPETITIONS" --networks "$core_networks" --encoder vt
}

matrix_v2() {
  loopback matrix-v2 matrix-v2 1 --networks "$other_networks" --encoder vt
}

custom() {
  loopback custom custom "$TIER1_REPETITIONS" --networks "$TIER1_NETWORKS" --source "$TIER1_SOURCE" \
    --encoder "$TIER1_ENCODER" $(scenes)
}

gate_v2() {
  loopback gate-v2 gate-v2 "$TIER1_REPETITIONS" "${gate_options[@]}"
}

pr_gate() {
  loopback first-v2 gate-v2 "$TIER1_REPETITIONS" "${gate_options[@]}" &&
    loopback second-v2 gate-v2 "$TIER1_REPETITIONS" "${gate_options[@]}"
}

: >"$results/reports.txt"
"$scripts/record-installed-commit.sh" "$results"
uptime >"$results/load-before.txt"
"$mode"
status=$?
uptime >"$results/load-after.txt"
exit "$status"

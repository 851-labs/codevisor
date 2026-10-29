#!/usr/bin/env bash
set -uo pipefail

results=${1:-}
matrices=${2:-2}
own_window=${3:-true}
duration=${4:-12}
scenes=${5:-}
networks=${6:-}
[[ -n "$results" && "$matrices" =~ ^[1-3]$ && "$duration" =~ ^[0-9]{1,2}$ ]] && (( 10#$duration >= 6 && 10#$duration <= 60 )) || {
  echo "Usage: $0 <results-directory> [1-3 matrices] [own-window true|false] [6-60 seconds per scene] [scenes] [networks]" >&2
  exit 2
}
duration=$(( 10#$duration ))
matrix_options=(--duration "$duration")
[[ -z "$scenes" ]] || matrix_options+=(--scenes "$scenes")
[[ -z "$networks" ]] || matrix_options+=(--networks "$networks")
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run_id="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
mkdir -p "$results"
failed=0

loopback() {
  local name=$1
  shift
  local started
  started=$(date +%s)
  "$scripts/run-installed.sh" loopback --run-id "$run_id-$name" --trigger "${GITHUB_EVENT_NAME:-manual}" \
    --output "$results/$name.json" "$@" >/dev/null 2>"$results/$name.log" || { echo "$name failed" >&2; failed=1; }
  echo "$(( $(date +%s) - started ))" >"$results/$name-seconds.txt"
  grep -E '^(\[|\||#)' "$results/$name.log" >"$results/$name.md" || true
}

summarize() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" && -s "$results/$1.md" ]] || return 0
  { echo "### $(hostname -s): $1 ($(cat "$results/$1-seconds.txt") s)"; cat "$results/$1.md"; echo; } >>"$GITHUB_STEP_SUMMARY"
}

"$scripts/record-installed-commit.sh" "$results"
uptime >"$results/load-before.txt"
for matrix in $(seq 1 "$matrices"); do
  loopback "matrix-$matrix" --frames "$results/matrix-$matrix-frames.jsonl" "${matrix_options[@]}"
  uptime >"$results/load-after-matrix-$matrix.txt"
done
if [[ "$own_window" == true ]]; then
  loopback own-window --source own-window --scenes scroll --networks N0 --duration "$duration"
fi
uptime >"$results/load-after.txt"
for name in $(seq -f "matrix-%g" 1 "$matrices") own-window; do summarize "$name"; done
exit "$failed"

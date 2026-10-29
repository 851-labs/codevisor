#!/usr/bin/env bash
set -uo pipefail

results=${1:-}
[[ -n "$results" ]] || { echo "Usage: $0 <results-directory>" >&2; exit 2; }
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$results"
failed=0
content=""
trap '[[ -z "$content" ]] || kill "$content" 2>/dev/null' EXIT

summarize() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" && -s "$results/$1.json" ]] || return 0
  { echo "### $(hostname -s): $1"; echo '```json'; cat "$results/$1.json"; echo '```'; } >>"$GITHUB_STEP_SUMMARY"
}

run_check() {
  local name=$1
  shift
  "$scripts/run-installed.sh" "$@" >"$results/$name.json" || { echo "$name failed" >&2; failed=1; }
}

"$scripts/record-installed-commit.sh" "$results"
uptime >"$results/load-before.txt"
"$scripts/run-installed.sh" calibrate --check on-glass --duration 30 >"$results/on-glass.json" &
content=$!
sleep 3
run_check observe observe --duration 20
wait "$content" || { echo "on-glass failed" >&2; failed=1; }
content=""
run_check c6 calibrate --check c6
uptime >"$results/load-after.txt"
for result in on-glass observe c6; do summarize "$result"; done
exit "$failed"

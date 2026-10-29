#!/usr/bin/env bash
set -euo pipefail

results=${1:-}
[[ -n "$results" ]] || { echo "Usage: $0 <results-directory>" >&2; exit 2; }
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -s "$results/reports.txt" ]] || { echo "## Screen sharing bench: no report (see the job log)"; exit 0; }

"$scripts/results-branch.sh" index "$results/index.jsonl"
while read -r name; do
  options=(--report "$results/$name.json" --index "$results/index.jsonl")
  [[ -f "$results/preflight.json" ]] && options+=(--preflight "$results/preflight.json")
  if [[ -f "$results/published-$name.json" ]]; then
    commit="$(plutil -extract commit raw "$results/published-$name.json")"
    chart="$(plutil -extract chart raw "$results/published-$name.json")"
    options+=(--chart-url "https://raw.githubusercontent.com/$GITHUB_REPOSITORY/$commit/$chart")
  fi
  "$scripts/run-installed.sh" summarize "${options[@]}"
  echo
done <"$results/reports.txt"

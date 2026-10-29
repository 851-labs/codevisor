#!/usr/bin/env bash
set -euo pipefail

results=${1:-}
[[ -n "$results" ]] || { echo "Usage: $0 <results-directory>" >&2; exit 2; }
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -s "$results/reports.txt" ]] || { echo "no reports to record" >&2; exit 0; }

while read -r name; do
  "$scripts/results-branch.sh" publish "$results/$name.json" "$results/published-$name.json"
done <"$results/reports.txt"

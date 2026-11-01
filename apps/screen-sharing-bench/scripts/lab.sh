#!/usr/bin/env bash
set -euo pipefail

results=${1:-}
machine=${2:-}
[[ -n "$results" && -n "$machine" && $# -ge 3 ]] || {
  echo "Usage: $0 <results-directory> <machine> <subcommand> [--option value …]" >&2
  exit 2
}
shift 2
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$results"
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

"$scripts/run-installed.sh" preflight >"$results/before-preflight.json" || true
"$scripts/run-installed.sh" "$@" >"$results/command.json" 2>"$results/command.err" &
command_job=$!
sleep 8
"$scripts/run-installed.sh" preflight >"$results/during-preflight.json" || true
status=0
wait "$command_job" || status=$?
{
  echo "## Lab on $machine: \`$*\` exited $status"
  echo
  echo "Displays during the command: $(plutil -extract displays json -o - "$results/during-preflight.json" 2>/dev/null || echo unknown)"
  echo
  echo '```json'
  cat "$results/command.json"
  echo '```'
  echo
  echo '```'
  tail -n 40 "$results/command.err"
  echo '```'
} | tee -a "$summary"
exit "$status"

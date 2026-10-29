#!/usr/bin/env bash
set -euo pipefail

host=${1:-}
minutes=${2:-}
rendezvous_seconds=${3:-}
results=${4:-}
[[ -n "$host" && -n "$minutes" && -n "$rendezvous_seconds" && -n "$results" ]] || {
  echo "Usage: $0 <responder-ipv4> <minutes> <rendezvous-seconds> <results-directory>" >&2
  exit 2
}
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$results"

responder_answers() {
  { "$scripts/run-installed.sh" calibrate --check c2 --responder "$host" --duration 2 || true; } |
    grep -q '"replies" : [1-9]'
}

deadline=$((SECONDS + rendezvous_seconds))
until responder_answers; do
  ((SECONDS < deadline)) || { echo "No clock probe responder at $host after $rendezvous_seconds s" >&2; exit 1; }
  sleep 10
done

status=0
"$scripts/run-installed.sh" calibrate --check c2 --responder "$host" --duration "$((minutes * 60))" \
  --output "$results/c2-exchanges.jsonl" >"$results/c2.json" || status=$?
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  { echo "### $(hostname -s): c2"; echo '```json'; cat "$results/c2.json"; echo '```'; } >>"$GITHUB_STEP_SUMMARY"
fi
exit "$status"

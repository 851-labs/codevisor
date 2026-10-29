#!/usr/bin/env bash
set -euo pipefail

host=${1:-}
[[ -n "$host" && $# -ge 2 ]] || { echo "Usage: $0 <ssh-host> <command> [--option value …]" >&2; exit 2; }
shift

remote_script='
set -euo pipefail
logs="$(mktemp -d /tmp/codevisor-bench.XXXXXX)"
opener=""
stop_app() {
  if [[ -s "$logs/pid" ]]; then kill "$(cat "$logs/pid")" 2>/dev/null || true; fi
  if [[ -n "$opener" ]]; then kill "$opener" 2>/dev/null || true; fi
  rm -rf "$logs"
}
trap stop_app EXIT
trap "exit 130" INT HUP TERM
echo 1 >"$logs/status"
open -W -n -a "$HOME/Applications/CodevisorBench.app" \
  --env "CODEVISOR_BENCH_PID_FILE=$logs/pid" --env "CODEVISOR_BENCH_STATUS_FILE=$logs/status" \
  --stdout "$logs/stdout" --stderr "$logs/stderr" --args "$@" &
opener=$!
wait "$opener"
opener=""
rm -f "$logs/pid"
cat "$logs/stdout"
cat "$logs/stderr" >&2
exit "$(cat "$logs/status")"
'

ssh -tt -o LogLevel=QUIET "$host" "bash -c $(printf '%q' "$remote_script") codevisor-bench $(printf '%q ' "$@")"

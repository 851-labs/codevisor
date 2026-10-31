#!/usr/bin/env bash
set -euo pipefail

[[ $# -ge 1 ]] || { echo "Usage: $0 <command> [--option value …]" >&2; exit 2; }

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
background=()
[[ -n "${CODEVISOR_BENCH_BACKGROUND:-}" ]] && background=(-g)
open -W -n ${background[@]+"${background[@]}"} -a "${CODEVISOR_BENCH_APP:-$HOME/Applications/CodevisorBench.app}" \
  --env "CODEVISOR_BENCH_PID_FILE=$logs/pid" --env "CODEVISOR_BENCH_STATUS_FILE=$logs/status" --env "CODEVISOR_SCREEN_TRANSPORT=${CODEVISOR_SCREEN_TRANSPORT:-}" \
  --stdout "$logs/stdout" --stderr "$logs/stderr" --args "$@" &
opener=$!
wait "$opener"
opener=""
rm -f "$logs/pid"
cat "$logs/stdout"
cat "$logs/stderr" >&2
exit "$(cat "$logs/status")"

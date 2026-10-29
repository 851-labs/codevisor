#!/usr/bin/env bash
set -euo pipefail

host=${1:-}
[[ -n "$host" && $# -ge 2 ]] || { echo "Usage: $0 <ssh-host> <command> [--option value …]" >&2; exit 2; }
shift

remote_script="$(cat "$(dirname "${BASH_SOURCE[0]}")/run-installed.sh")"

ssh -tt -o LogLevel=QUIET "$host" "bash -c $(printf '%q' "$remote_script") codevisor-bench $(printf '%q ' "$@")"

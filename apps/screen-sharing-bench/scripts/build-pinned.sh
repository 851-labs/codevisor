#!/usr/bin/env bash
set -euo pipefail

destination=${1:-}
[[ -n "$destination" ]] || { echo "Usage: $0 <directory for CodevisorBench.app>" >&2; exit 2; }
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bundle="$("$scripts/build.sh")"
mkdir -p "$destination"
rm -rf "$destination/CodevisorBench.app"
ditto "$bundle" "$destination/CodevisorBench.app"
echo "$destination/CodevisorBench.app"

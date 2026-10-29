#!/usr/bin/env bash
set -euo pipefail

host=${1:-}
[[ -n "$host" ]] || { echo "Usage: $0 <ssh-host>" >&2; exit 2; }
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
installed=Applications/CodevisorBench.app

bundle="$("$scripts/build.sh")"
ssh "$host" mkdir -p Applications
rsync -a --delete "$bundle/" "$host:$installed/"
ssh "$host" "codesign --verify --strict $installed && plutil -extract CodevisorBenchCommit raw $installed/Contents/Info.plist"
echo "Installed ~/$installed on $host"

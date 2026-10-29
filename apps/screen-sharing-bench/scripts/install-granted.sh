#!/usr/bin/env bash
set -euo pipefail

built=${CODEVISOR_BENCH_APP:-}
installed="$HOME/Applications/CodevisorBench.app"
[[ -n "$built" && -d "$built" ]] || { echo "CODEVISOR_BENCH_APP must name the built app" >&2; exit 2; }

mkdir -p "$HOME/Applications"
rsync -a --delete "$built/" "$installed/"
codesign --verify --strict "$installed"
echo "CODEVISOR_BENCH_APP=$installed" >>"${GITHUB_ENV:-/dev/null}"
echo "Installed $(plutil -extract CodevisorBenchCommit raw "$installed/Contents/Info.plist") at $installed"

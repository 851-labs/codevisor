#!/usr/bin/env bash
set -euo pipefail

host=${1:-}
force=${2:-}
[[ -n "$host" && ( -z "$force" || "$force" == --force ) ]] || { echo "Usage: $0 <ssh-host> [--force]" >&2; exit 2; }
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
installed=Applications/CodevisorBench.app

team() {
  sed -n 's/^TeamIdentifier=//p'
}

bundle="$("$scripts/build.sh")"
built_team="$(codesign -dv "$bundle" 2>&1 | team)"
installed_team="$(ssh "$host" "codesign -dv $installed 2>&1" | team || true)"
if [[ -n "$installed_team" && "$installed_team" != "$built_team" && "$force" != --force ]]; then
  echo "$host's installed app is signed by team $installed_team and this build by $built_team. macOS keeps one" >&2
  echo "Screen Recording and Accessibility grant per bundle ID, so deploying it needs new grants and breaks CI's." >&2
  echo "Pass --force to deploy anyway." >&2
  exit 1
fi
ssh "$host" mkdir -p Applications
rsync -a --delete "$bundle/" "$host:$installed/"
ssh "$host" "codesign --verify --strict $installed && plutil -extract CodevisorBenchCommit raw $installed/Contents/Info.plist"
echo "Installed ~/$installed on $host"

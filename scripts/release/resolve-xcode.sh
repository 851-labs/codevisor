#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
pinned="$(tr -d '[:space:]' < "$repo_root/.xcode-version")"
any_version=false
[[ "${1:-}" == "--any-version" ]] && any_version=true

version_of() {
  defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null || true
}

installed_xcodes() {
  for app in /Applications/Xcode.app /Applications/Xcode?*.app; do
    [[ -x "$app/Contents/Developer/usr/bin/xcodebuild" ]] && printf '%s\n' "$app"
  done
  return 0
}

while IFS= read -r app; do
  if [[ "$(version_of "$app")" == "$pinned" ]]; then
    printf '%s\n' "$app/Contents/Developer"
    exit 0
  fi
done < <(installed_xcodes)

if [[ "$any_version" == true ]]; then
  fallback="$(installed_xcodes | head -n 1)"
  if [[ -n "$fallback" ]]; then
    echo "Xcode $pinned isn't installed; using $(version_of "$fallback") from $fallback" >&2
    printf '%s\n' "$fallback/Contents/Developer"
    exit 0
  fi
fi

echo "Xcode $pinned (pinned in .xcode-version) is required under /Applications. Installed: $(installed_xcodes | while IFS= read -r app; do printf '%s %s; ' "$app" "$(version_of "$app")"; done)" >&2
exit 1

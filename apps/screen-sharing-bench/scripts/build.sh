#!/usr/bin/env bash
set -euo pipefail

app_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$app_root/../.." && pwd)"
package_path="$repo_root/packages/swift"
bundle="$app_root/.build/CodevisorBench.app"
team_id=WH4QW9ND3J

signing_identity() {
  if [[ -n "${CODEVISOR_BENCH_SIGNING_IDENTITY:-}" ]]; then
    echo "$CODEVISOR_BENCH_SIGNING_IDENTITY"
    return
  fi
  security find-identity -v -p codesigning |
    awk -v team="($team_id)\"" '!found && /"Developer ID Application: / && index($0, team) { print $2; found = 1 }'
}

source_commit() {
  local commit
  local changes
  commit="$(git -C "$repo_root" rev-parse HEAD)"
  changes="$(git -C "$repo_root" status --porcelain --ignore-submodules=all)"
  if [[ -n "$changes" ]]; then
    echo "Building from a changed checkout:" >&2
    echo "$changes" | head -20 >&2
    commit="$commit-dirty"
  fi
  echo "$commit"
}

identity="$(signing_identity)"
if [[ -z "$identity" ]]; then
  echo "No Developer ID Application identity for team $team_id. Set CODEVISOR_BENCH_SIGNING_IDENTITY." >&2
  exit 1
fi

cd "$repo_root"
node scripts/net-artifact.mjs ensure-swift >&2
swift build -c release --package-path "$package_path" --product CodevisorBench >&2
products="$(swift build -c release --package-path "$package_path" --show-bin-path)"

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Frameworks"
cp "$app_root/Info.plist" "$bundle/Contents/Info.plist"
plutil -insert CodevisorBenchCommit -string "$(source_commit)" "$bundle/Contents/Info.plist"
cp "$products/CodevisorBench" "$bundle/Contents/MacOS/CodevisorBench"
install_name_tool -add_rpath @executable_path/../Frameworks "$bundle/Contents/MacOS/CodevisorBench"
ditto "$products/WebRTC.framework" "$bundle/Contents/Frameworks/WebRTC.framework"
codesign --force --sign "$identity" "$bundle/Contents/Frameworks/WebRTC.framework" >&2
codesign --force --sign "$identity" "$bundle" >&2
codesign --verify --strict "$bundle"
echo "$bundle"

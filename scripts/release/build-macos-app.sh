#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

usage() {
  cat >&2 <<'EOF'
usage: scripts/release/build-macos-app.sh <version> <output-dir>

Builds the Apple silicon Codevisor.app, bundles the darwin-arm64 local server
runtime into Contents/Resources/server, optionally signs, and writes:
  Codevisor-macOS-arm64.zip   app archive (Homebrew cask, in-app updater)
  Codevisor-arm64.dmg         disk image (website)

Both artifacts are signed but not notarized. Run notarize-macos-app.sh on the
output directory before distributing them; CI does that in Publish Alpha so
Apple's notary quota is spent only on builds that actually ship.

The app does not support Intel Macs; they run the standalone
codevisor-server-darwin-x64 archive instead.

Optional environment:
  APPLE_CODESIGN_IDENTITY       Developer ID Application identity, or empty for ad-hoc signing.
  CODEVISOR_XCODE_SCHEME          Defaults to Codevisor.
  CODEVISOR_BUILD_NUMBER          Defaults to GITHUB_RUN_NUMBER or 1.
  CODEVISOR_SOURCE_REVISION       Git commit recorded in the app bundle.
  CODEVISOR_CLEAN_DERIVED_DATA    Set to 1 to discard incremental Xcode state.
  CODEVISOR_UNSIGNED_APP_ARCHIVE_OUTPUT
                                  Optional path to save the unsigned app for caching.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

version="${1:-}"
output_dir="${2:-}"

if [[ -z "$version" || -z "$output_dir" ]]; then
  usage
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
derived_data="$repo_root/dist/release/DerivedData"
runtime_root="$repo_root/dist/release/work/app-server-runtimes"
node_entitlements="$script_dir/node-entitlements.plist"
host_target="$("$script_dir/detect-target.sh")"
build_number="${CODEVISOR_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
source_revision="${CODEVISOR_SOURCE_REVISION:-${GITHUB_SHA:-unknown}}"
release_started_at=$SECONDS
phase_started_at=$SECONDS

finish_phase() {
  local label="$1"
  local elapsed=$((SECONDS - phase_started_at))
  echo "Release timing: $label completed in ${elapsed}s"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::notice title=Release timing::$label completed in ${elapsed}s"
  fi
  phase_started_at=$SECONDS
}

server_target="darwin-arm64"

prepare_server_runtime() {
  local destination="$runtime_root/$server_target"
  if [[ "$host_target" != "$server_target" ]]; then
    echo "error: the macOS app bundles a $server_target server and must be built on $server_target, not $host_target" >&2
    exit 1
  fi
  rm -rf "$destination"
  "$script_dir/build-server-runtime.sh" "$version" "$destination" "$server_target"

  if [[ ! -x "$destination/bin/node" || ! -f "$destination/main.js" ]]; then
    echo "error: incomplete $server_target server runtime at $destination" >&2
    exit 1
  fi
  if ! lipo -archs "$destination/bin/node" | tr " " "\n" | grep -qx arm64; then
    echo "error: $server_target server runtime has a Node binary without arm64 support" >&2
    lipo -info "$destination/bin/node" >&2 || true
    exit 1
  fi
}

mkdir -p "$output_dir"
(cd "$repo_root" && bun run build)
rm -rf "$runtime_root"
prepare_server_runtime
finish_phase "Local server build and runtime preparation"

if [[ "${CODEVISOR_CLEAN_DERIVED_DATA:-}" == 1 ]]; then
  rm -rf "$derived_data"
fi
app_path="$derived_data/Build/Products/Release/Codevisor.app"
"$script_dir/build-macos-xcode.sh" "$derived_data"
if [[ -n "${CODEVISOR_UNSIGNED_APP_ARCHIVE_OUTPUT:-}" ]]; then
  mkdir -p "$(dirname "$CODEVISOR_UNSIGNED_APP_ARCHIVE_OUTPUT")"
  rm -f "$CODEVISOR_UNSIGNED_APP_ARCHIVE_OUTPUT"
  ditto --norsrc -c -k --keepParent "$app_path" "$CODEVISOR_UNSIGNED_APP_ARCHIVE_OUTPUT"
fi
finish_phase "Xcode build"

if [[ ! -d "$app_path" ]]; then
  echo "error: Codevisor.app was not produced at $app_path" >&2
  exit 1
fi

plist_path="$app_path/Contents/Info.plist"
# Xcode builds with stable placeholder metadata so a default-branch warm build
# can be reused by a tag build of the same commit. Stamp the shipping metadata
# into the unsigned product; changing it after signing would invalidate the
# bundle signature and break the in-app updater's signature check.
set_plist_string() {
  local key="$1" value="$2"
  if /usr/libexec/PlistBuddy -c "Print :$key" "$plist_path" >/dev/null 2>&1; then
    /usr/bin/plutil -replace "$key" -string "$value" "$plist_path"
  else
    /usr/bin/plutil -insert "$key" -string "$value" "$plist_path"
  fi
}
set_plist_string CFBundleShortVersionString "$version"
set_plist_string CFBundleVersion "$build_number"
set_plist_string CodevisorSourceRevision "$source_revision"
stamped_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist_path")"
stamped_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist_path")"
if [[ "$stamped_version" != "$version" || "$stamped_build" != "$build_number" ]]; then
  echo "error: failed to stamp release metadata into $plist_path" >&2
  echo "expected version/build $version/$build_number, found $stamped_version/$stamped_build" >&2
  exit 1
fi
echo "Stamped Codevisor.app version $stamped_version (build $stamped_build, revision $source_revision)"

# Xcode's Icon Composer pipeline owns app icon generation. Keep the compiled
# asset catalog in the bundle so LaunchServices resolves the .icon file output.
# CFBundleIconFile is legacy and can be omitted by Xcode's asset catalog path.
if [[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$plist_path")" != "AppIcon" ]]; then
  echo "error: expected CFBundleIconName=AppIcon in $plist_path" >&2
  exit 1
fi
if [[ ! -e "$app_path/Contents/Resources/Assets.car" ]]; then
  echo "error: expected Xcode to compile Icon Composer assets into Assets.car" >&2
  exit 1
fi

server_resources="$app_path/Contents/Resources/server"
rm -rf "$server_resources"
mkdir -p "$server_resources/$server_target"
cp -R "$runtime_root/$server_target/." "$server_resources/$server_target/"
agent_source="$repo_root/apps/macos/Codevisor/Resources/codevisor-server-agent"
agent_destination="$app_path/Contents/Resources/codevisor-server-agent"
launch_agent_source="$repo_root/apps/macos/Codevisor/LaunchAgents/com.851labs.Codevisor.ServerAgent.plist"
launch_agent_destination="$app_path/Contents/Library/LaunchAgents/com.851labs.Codevisor.ServerAgent.plist"
mkdir -p "$(dirname "$launch_agent_destination")"
cp "$agent_source" "$agent_destination"
cp "$launch_agent_source" "$launch_agent_destination"
# The synchronized Xcode group also sees the source plist as a resource.
# SMAppService requires it only in Contents/Library/LaunchAgents.
rm -f "$app_path/Contents/Resources/$(basename "$launch_agent_source")"
chmod +x "$agent_destination"
find "$app_path" -name "._*" -delete

identity="${APPLE_CODESIGN_IDENTITY:-}"
if [[ -n "$identity" ]]; then
  sign_args=(--force --options runtime --timestamp --sign "$identity")
else
  sign_args=(--force --sign -)
fi

# Xcode copies the prebuilt Sparkle framework while code signing is disabled.
# Re-sign its independently sealed components inside-out with Codevisor's
# identity, preserving the helper entitlement Sparkle uses for installation.
sparkle_framework="$app_path/Contents/Frameworks/Sparkle.framework"
sparkle_version="$sparkle_framework/Versions/Current"
sparkle_components=(
  "$sparkle_version/Autoupdate"
  "$sparkle_version/Updater.app"
  "$sparkle_version/XPCServices/Downloader.xpc"
  "$sparkle_version/XPCServices/Installer.xpc"
)
for component in "${sparkle_components[@]}"; do
  [[ -e "$component" ]] || { echo "error: missing Sparkle component: $component" >&2; exit 1; }
  codesign "${sign_args[@]}" --preserve-metadata=entitlements "$component"
done
codesign "${sign_args[@]}" --preserve-metadata=entitlements "$sparkle_framework"
codesign --verify --deep --strict "$sparkle_framework"

# Chromium contains separately signed libraries and sandboxed helper apps.
# Re-sign inside-out with the release identity, retaining renderer JIT rights.
node "$script_dir/macos-browser-artifact.mjs" sign-libraries "$app_path" "${identity:--}"
while IFS= read -r library; do
  codesign "${sign_args[@]}" "$library"
done < <(find "$app_path/Contents/Frameworks/Chromium Embedded Framework.framework" -name "*.dylib" -type f)
while IFS= read -r helper; do
  codesign "${sign_args[@]}" --preserve-metadata=entitlements "$helper"
done < <(find "$app_path/Contents/Frameworks" -maxdepth 1 -name "Codevisor Browser Helper*.app" -type d)

# Every other embedded framework needs the same treatment for a simpler
# reason: a binary xcframework (Sentry) ships completely unsigned, and Xcode
# embeds it with signing disabled, so nothing ever seals it. Signing the app
# does not reach it either — that is a shallow signature by design.
#
# An unsigned nested bundle only surfaces at the app's deep verification after
# the outer signature below, and it surfaces as "code has no resources but signature indicates they
# must be present" — a message that describes the enclosing app rather than
# the framework that is actually unsigned. Seal them here, next to the reason.
#
# Deliberately a sweep rather than a name: the next vendored framework should
# not reintroduce a failure that lands minutes later under a misleading error.
while IFS= read -r framework; do
  [[ -n "$framework" ]] || continue
  [[ "$(basename "$framework")" != "Sparkle.framework" ]] || continue
  codesign "${sign_args[@]}" --preserve-metadata=entitlements "$framework"
  codesign --verify --deep --strict "$framework"
done < <(find "$app_path/Contents/Frameworks" -maxdepth 1 -name "*.framework" -type d 2>/dev/null)

# Sign every Mach-O in the bundled server runtimes. Detection is batched
# through one xargs/file pipeline: the runtimes hold ~21k files but only ~14
# Mach-O binaries, and the previous per-file `file` invocation spent ~4
# minutes on process spawns alone. Paths from `file` output are newline-split,
# which is safe here because npm rejects package files with newlines in names.
macho_manifest="$repo_root/dist/release/work/macho-manifest.txt"
mkdir -p "$(dirname "$macho_manifest")"
find "$server_resources" -type f -print0 \
  | xargs -0 file --no-pad \
  | grep ": Mach-O" \
  | sed 's/: Mach-O.*//' > "$macho_manifest"

# The Node executables carry JIT entitlements; everything else signs in
# parallel batches (each --timestamp signature round-trips to Apple's
# timestamp service, so parallelism hides the network latency).
while IFS= read -r macho; do
  case "$macho" in
    "$server_resources"/*/bin/node)
      codesign "${sign_args[@]}" --entitlements "$node_entitlements" "$macho"
      ;;
  esac
done < "$macho_manifest"
{ grep -v "/bin/node$" "$macho_manifest" || true; } | tr '\n' '\0' \
  | xargs -0 -n 8 -P 4 codesign "${sign_args[@]}"

codesign "${sign_args[@]}" "$app_path"
codesign --verify --deep --strict "$app_path"
if [[ -n "$identity" ]]; then
  node "$script_dir/macos-browser-artifact.mjs" distribution "$app_path" arm64
fi

# Exercise the signed runtime before archiving. This catches production-only
# signing and native-addon ABI drift that the Debug app cannot expose.
(cd "$server_resources/$server_target" && ./bin/node -e 'require("better-sqlite3"); console.log(`Packaged Node runtime smoke passed: ${process.version}`)')

finish_phase "Bundle signing and runtime smoke tests"

# Builds a signed DMG for direct download from www.codevisor.dev (installs
# without Homebrew). notarize-macos-app.sh later notarizes and staples it; the
# app inside shares the ZIP copy's signature, so one DMG ticket covers both.
make_dmg() {
  local app="$1" dmg="$2" staging="$3"
  local dmg_root="$repo_root/dist/release/work/dmg-root-$staging"
  rm -rf "$dmg_root" "$dmg"
  mkdir -p "$dmg_root"
  ditto "$app" "$dmg_root/Codevisor.app"
  ln -s /Applications "$dmg_root/Applications"
  hdiutil create -volname "Codevisor" -srcfolder "$dmg_root" -fs HFS+ -format UDZO -ov "$dmg"
  if [[ -n "$identity" ]]; then
    codesign --force --sign "$identity" "$dmg"
  fi
}

ditto --norsrc -c -k --keepParent "$app_path" "$output_dir/Codevisor-macOS-arm64.zip"
make_dmg "$app_path" "$output_dir/Codevisor-arm64.dmg" "arm64"
finish_phase "Artifact packaging"

artifacts=(
  "$output_dir/Codevisor-macOS-arm64.zip"
  "$output_dir/Codevisor-arm64.dmg"
)
for artifact in "${artifacts[@]}"; do
  shasum -a 256 "$artifact" | awk '{print $1}' > "$artifact.sha256"
done
finish_phase "Artifact checksums"
echo "Release timing: macOS app archive completed in $((SECONDS - release_started_at))s total"
echo "$output_dir/Codevisor-macOS-arm64.zip"

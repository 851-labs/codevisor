#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

usage() {
  cat >&2 <<'EOF'
usage: scripts/release/build-macos-app.sh <version> <output-dir>

Builds the Apple silicon Codevisor.app, bundles the darwin-arm64 local server
runtime into Contents/Resources/server, optionally signs/notarizes, and writes:
  Codevisor-macOS-arm64.zip   app archive (Homebrew cask, in-app updater)
  Codevisor-arm64.dmg         disk image (website)

The app does not support Intel Macs; they run the standalone
codevisor-server-darwin-x64 archive instead.

Optional environment:
  APPLE_CODESIGN_IDENTITY       Developer ID Application identity, or empty for ad-hoc signing.
  APPLE_ID                      Apple ID used for notarization.
  APPLE_APP_SPECIFIC_PASSWORD   App-specific password for notarytool.
  APPLE_TEAM_ID                 Apple team id for notarytool.
  APP_STORE_CONNECT_API_KEY_PATH
                                Path to App Store Connect API key .p8 for notarization.
  APP_STORE_CONNECT_API_KEY_ID  App Store Connect API key id for notarization.
  APP_STORE_CONNECT_ISSUER_ID   App Store Connect issuer id for notarization.
  CODEVISOR_XCODE_SCHEME          Defaults to Codevisor.
  CODEVISOR_BUILD_NUMBER          Defaults to GITHUB_RUN_NUMBER or 1.
  CODEVISOR_SOURCE_REVISION       Git commit recorded in the app bundle.
  CODEVISOR_CLEAN_DERIVED_DATA    Set to 1 to discard incremental Xcode state.
  CODEVISOR_UNSIGNED_APP_ARCHIVE_OUTPUT
                                  Optional path to save the unsigned app for caching.
  CODEVISOR_DARWIN_ARM64_RUNTIME_ARCHIVE_OUTPUT
                                  Optional path to save the ARM runtime for reuse.
  CODEVISOR_DARWIN_ARM64_RUNTIME_ARCHIVE
                                Optional prebuilt darwin-arm64 server runtime tarball.
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
  local archive="${CODEVISOR_DARWIN_ARM64_RUNTIME_ARCHIVE:-}"
  rm -rf "$destination"
  mkdir -p "$destination"

  if [[ -n "$archive" ]]; then
    if [[ ! -f "$archive" ]]; then
      echo "error: server runtime archive for $server_target does not exist: $archive" >&2
      exit 1
    fi
    tar -C "$destination" -xzf "$archive"
  elif [[ "$host_target" == "$server_target" ]]; then
    "$script_dir/build-server-runtime.sh" "$version" "$destination" "$server_target"
  else
    echo "error: building on $host_target requires CODEVISOR_DARWIN_ARM64_RUNTIME_ARCHIVE" >&2
    exit 1
  fi

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
if [[ -n "${CODEVISOR_DARWIN_ARM64_RUNTIME_ARCHIVE_OUTPUT:-}" ]]; then
  mkdir -p "$(dirname "$CODEVISOR_DARWIN_ARM64_RUNTIME_ARCHIVE_OUTPUT")"
  tar -C "$runtime_root/darwin-arm64" -czf "$CODEVISOR_DARWIN_ARM64_RUNTIME_ARCHIVE_OUTPUT" .
fi
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

# Artifact uploads to Apple's notary service run concurrently, and all
# submissions are created before waiting. Apple's processing queue dominates
# this stage, so starting every scan as early as possible reduces wall time.
notary_args=()
if [[ -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" && -n "${APP_STORE_CONNECT_API_KEY_ID:-}" && -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
  notary_args=(
    --key "$APP_STORE_CONNECT_API_KEY_PATH"
    --key-id "$APP_STORE_CONNECT_API_KEY_ID"
    --issuer "$APP_STORE_CONNECT_ISSUER_ID"
  )
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  notary_args=(
    --apple-id "$APPLE_ID"
    --password "$APPLE_APP_SPECIFIC_PASSWORD"
    --team-id "$APPLE_TEAM_ID"
  )
fi

# Prints the submission id for a file handed to the notary service.
# (Only called when notary_args is non-empty; macOS's bash 3.2 rejects
# empty-array expansion under `set -u`.)
submit_for_notarization() {
  local path="$1" response id
  response="$(xcrun notarytool submit "$path" "${notary_args[@]}" --output-format json)"
  id="$(printf '%s' "$response" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  if [[ -z "$id" ]]; then
    echo "error: could not parse notarization submission id for $path" >&2
    printf '%s\n' "$response" >&2
    return 1
  fi
  printf '%s' "$id"
}

submit_for_notarization_to_file() {
  local path="$1" id_file="$2" label="$3" started_at=$SECONDS id
  id="$(submit_for_notarization "$path")"
  printf '%s' "$id" > "$id_file"
  echo "Notarization submitted for $label in $((SECONDS - started_at))s ($id)"
}

# Stapling fetches the ticket from Apple's CDN (CloudKit). Right after a
# submission is accepted the ticket can briefly be unavailable (stapler error
# 68, a "retry-after" response), which failed Alpha builds whose notarization
# had succeeded. Retry a bounded number of times; a ticket that never appears
# still fails the build, so nothing unstapled is published.
staple_with_retry() {
  local target="$1" attempt
  for attempt in 1 2 3 4 5; do
    xcrun stapler staple "$target" && return 0
    [[ "$attempt" == 5 ]] && break
    echo "warning: stapling $(basename "$target") failed (attempt $attempt); retrying in $((attempt * 30))s" >&2
    sleep $((attempt * 30))
  done
  echo "error: stapling $(basename "$target") failed after $attempt attempts" >&2
  return 1
}

wait_for_notarization() {
  local id="$1" label="$2" response status attempt
  # Bounded wait: healthy notarizations return in minutes; a stuck Apple-side
  # queue (e.g. a new team's first-submission review) must fail this build
  # fast instead of holding the CI job until its own 6-hour timeout. The job
  # stays red — never publish unstapled artifacts — and simply passes on a
  # later run once Apple's queue clears.
  #
  # A TRANSPORT failure is different from a verdict: notarytool dying on an
  # HTTP timeout leaves no status at all, while the submission is still
  # perfectly valid on Apple's side. Re-poll the same submission a bounded
  # number of times before giving up — only a real verdict is terminal.
  status=""
  for attempt in 1 2 3 4 5; do
    response="$(xcrun notarytool wait "$id" "${notary_args[@]}" \
      --timeout "${CODEVISOR_NOTARY_WAIT_TIMEOUT:-30m}" --output-format json)" || true
    status="$(printf '%s' "$response" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    [[ -n "$status" ]] && break
    echo "warning: no notarization status for $label (submission $id) on attempt $attempt — Apple's API did not answer; retrying" >&2
    sleep 30
  done
  if [[ "$status" == "In Progress" ]]; then
    echo "error: notarization of $label still in progress after ${CODEVISOR_NOTARY_WAIT_TIMEOUT:-30m} (submission $id); Apple's queue is slow — retry this job later" >&2
    exit 1
  fi
  if [[ "$status" != "Accepted" ]]; then
    echo "error: notarization of $label finished with status '${status:-unknown}' (submission $id)" >&2
    xcrun notarytool log "$id" "${notary_args[@]}" >&2 || true
    exit 1
  fi
  echo "Notarization accepted for $label ($id)"
}

notary_work="$repo_root/dist/release/work/notary-submissions"
notary_pids=()
if [[ ${#notary_args[@]} -gt 0 ]]; then
  rm -rf "$notary_work"
  mkdir -p "$notary_work"
fi

# Builds a signed DMG for direct download from www.codevisor.dev (installs
# without Homebrew). Built from the signed (not yet stapled) app so its
# notarization overlaps the other submissions; the DMG itself is stapled for
# offline Gatekeeper checks and the app inside shares the stapled zip copy's
# signature, so its ticket resolves online.
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

if [[ ${#notary_args[@]} -gt 0 ]]; then
  submit_for_notarization_to_file "$output_dir/Codevisor-macOS-arm64.zip" "$notary_work/arm-zip.id" "Codevisor-macOS-arm64.zip" &
  notary_pids+=("$!")
  submit_for_notarization_to_file "$output_dir/Codevisor-arm64.dmg" "$notary_work/arm-dmg.id" "Codevisor-arm64.dmg" &
  notary_pids+=("$!")

  submission_failed=0
  for submission_pid in "${notary_pids[@]}"; do
    if ! wait "$submission_pid"; then
      submission_failed=1
    fi
  done
  if [[ "$submission_failed" != 0 ]]; then
    echo "error: one or more notarization submissions failed" >&2
    exit 1
  fi

  arm_zip_submission="$(<"$notary_work/arm-zip.id")"
  arm_dmg_submission="$(<"$notary_work/arm-dmg.id")"
  finish_phase "Notarization submissions"

  wait_for_notarization "$arm_zip_submission" "Codevisor-macOS-arm64.zip"
  staple_with_retry "$app_path"
  rm -f "$output_dir/Codevisor-macOS-arm64.zip"
  ditto --norsrc -c -k --keepParent "$app_path" "$output_dir/Codevisor-macOS-arm64.zip"

  wait_for_notarization "$arm_dmg_submission" "Codevisor-arm64.dmg"
  staple_with_retry "$output_dir/Codevisor-arm64.dmg"
  finish_phase "Notarization waits, stapling, and final ZIPs"
fi

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

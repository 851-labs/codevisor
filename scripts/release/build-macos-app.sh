#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

usage() {
  cat >&2 <<'EOF'
usage: scripts/release/build-macos-app.sh <version> <output-dir>

Builds the universal Codevisor.app, bundles both local server runtimes into
Contents/Resources/server, optionally signs/notarizes, and writes:
  Codevisor-macOS-{arm64,x64}.zip   per-architecture apps (Homebrew cask,
                                    in-app updater)
  Codevisor-{arm64,x64}.dmg         per-architecture disk images (website)

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
  CODEVISOR_DARWIN_X64_RUNTIME_ARCHIVE
                                Optional prebuilt darwin-x64 server runtime tarball.
  CODEVISOR_RUNTIME_ARCHIVE_WAIT_SECONDS
                                Seconds to wait for a prebuilt runtime archive.
  CODEVISOR_RUNTIME_ARCHIVE_FAILURE_MARKER
                                Optional file signaling an asynchronous download failure.
  CODEVISOR_REQUIRE_UNIVERSAL_MACOS_APP
                                Set to 1 to require both macOS server runtimes.
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

runtime_archive_for_target() {
  case "$1" in
    darwin-arm64)
      printf "%s" "${CODEVISOR_DARWIN_ARM64_RUNTIME_ARCHIVE:-}"
      ;;
    darwin-x64)
      printf "%s" "${CODEVISOR_DARWIN_X64_RUNTIME_ARCHIVE:-}"
      ;;
    *)
      return 1
      ;;
  esac
}

node_arch_for_target() {
  case "$1" in
    darwin-arm64)
      printf "arm64"
      ;;
    darwin-x64)
      printf "x86_64"
      ;;
    *)
      return 1
      ;;
  esac
}

prepare_server_runtime() {
  local target="$1"
  local destination="$runtime_root/$target"
  local archive
  archive="$(runtime_archive_for_target "$target")"
  rm -rf "$destination"
  mkdir -p "$destination"

  if [[ -n "$archive" ]]; then
    local wait_seconds="${CODEVISOR_RUNTIME_ARCHIVE_WAIT_SECONDS:-0}"
    local failure_marker="${CODEVISOR_RUNTIME_ARCHIVE_FAILURE_MARKER:-}"
    local deadline
    if [[ "$wait_seconds" == *[!0-9]* ]]; then
      echo "error: CODEVISOR_RUNTIME_ARCHIVE_WAIT_SECONDS must be a non-negative integer" >&2
      exit 1
    fi
    deadline=$((SECONDS + wait_seconds))
    while [[ ! -f "$archive" && $SECONDS -lt $deadline ]]; do
      if [[ -n "$failure_marker" && -f "$failure_marker" ]]; then
        echo "error: asynchronous server runtime download failed for $target" >&2
        exit 1
      fi
      echo "Waiting for $target server runtime archive..."
      sleep 5
    done
    if [[ ! -f "$archive" ]]; then
      echo "error: server runtime archive for $target does not exist: $archive" >&2
      exit 1
    fi
    tar -C "$destination" -xzf "$archive"
  elif [[ "$target" == "$host_target" ]]; then
    "$script_dir/build-server-runtime.sh" "$version" "$destination" "$target"
  elif [[ "${CODEVISOR_REQUIRE_UNIVERSAL_MACOS_APP:-}" == 1 ]]; then
    echo "error: CODEVISOR_REQUIRE_UNIVERSAL_MACOS_APP=1 but no $target runtime archive was provided" >&2
    exit 1
  else
    rm -rf "$destination"
    return 0
  fi

  if [[ ! -x "$destination/bin/node" || ! -f "$destination/main.js" ]]; then
    echo "error: incomplete $target server runtime at $destination" >&2
    exit 1
  fi
  local expected_arch
  expected_arch="$(node_arch_for_target "$target")"
  if ! lipo -archs "$destination/bin/node" | tr " " "\n" | grep -qx "$expected_arch"; then
    echo "error: $target server runtime has a Node binary without $expected_arch support" >&2
    lipo -info "$destination/bin/node" >&2 || true
    exit 1
  fi
}

mkdir -p "$output_dir"
(cd "$repo_root" && bun run build)
rm -rf "$runtime_root"
prepare_server_runtime "darwin-arm64"
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
finish_phase "Universal Xcode build"

# The Intel runtime is produced on a native x86_64 runner. CI starts that
# artifact download while this runner prepares its local runtime and Xcode
# product, then we join it only when both runtimes are needed for bundling.
prepare_server_runtime "darwin-x64"
finish_phase "Intel runtime handoff"

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
mkdir -p "$server_resources"
for target in darwin-arm64 darwin-x64; do
  source_runtime="$runtime_root/$target"
  if [[ -d "$source_runtime" ]]; then
    mkdir -p "$server_resources/$target"
    cp -R "$source_runtime/." "$server_resources/$target/"
  fi
done
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

# Exercise the signed runtime before archiving. This catches production-only
# signing and native-addon ABI drift that the Debug app cannot expose.
(cd "$server_resources/$host_target" && ./bin/node -e 'require("better-sqlite3"); console.log(`Packaged Node runtime smoke passed: ${process.version}`)')

# Exercise the Intel runtime under Rosetta too, when available: executing any
# JS is enough to catch hardened-runtime entitlement mistakes that only crash
# x86_64 V8 (arm64 JIT uses MAP_JIT and different entitlement rules).
if [[ "$host_target" == "darwin-arm64" && -x "$server_resources/darwin-x64/bin/node" ]]; then
  if arch -x86_64 /usr/bin/true 2>/dev/null; then
    (cd "$server_resources/darwin-x64" && arch -x86_64 ./bin/node -e 'require("better-sqlite3"); console.log(`Packaged Intel Node runtime smoke passed: ${process.version}`)')
  else
    echo "Rosetta unavailable; skipping Intel runtime smoke" >&2
  fi
fi
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

wait_for_notarization() {
  local id="$1" label="$2" response status
  response="$(xcrun notarytool wait "$id" "${notary_args[@]}" --output-format json)" || true
  status="$(printf '%s' "$response" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
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

# Per-architecture variants, thinned from the signed universal bundle: half
# the download and installed size because each app carries one server runtime
# and one slice of the executable. The runtime files keep their signatures
# (they are copied unmodified); only the outer bundle re-signs after thinning.
split_work="$repo_root/dist/release/work/split"
rm -rf "$split_work"
mkdir -p "$split_work"

make_variant() {
  local lipo_arch="$1" suffix="$2" foreign_target="$3"
  local variant_app="$split_work/$suffix/Codevisor.app"
  local main_binary
  mkdir -p "$split_work/$suffix"
  ditto "$app_path" "$variant_app"

  # Thin only Codevisor's executable. Nested frameworks such as Sparkle are
  # independently sealed code: mutating their Mach-O files would invalidate
  # those seals and require rebuilding their full inside-out signature graph.
  # Keeping the small vendor framework universal preserves its signature while
  # still removing the large foreign server runtime from each app variant.
  main_binary="$variant_app/Contents/MacOS/Codevisor"
  lipo -thin "$lipo_arch" "$main_binary" -output "$main_binary.thin"
  mv "$main_binary.thin" "$main_binary"

  rm -rf "$variant_app/Contents/Resources/server/$foreign_target"
  if [[ ! -d "$variant_app/Contents/Resources/server" ]] \
    || [[ -z "$(ls "$variant_app/Contents/Resources/server")" ]]; then
    echo "error: $suffix variant lost its server runtime during thinning" >&2
    exit 1
  fi
  codesign "${sign_args[@]}" "$variant_app"
  codesign --verify --deep --strict "$variant_app"

  ditto --norsrc -c -k --keepParent "$variant_app" "$output_dir/Codevisor-macOS-$suffix.zip"
  make_dmg "$variant_app" "$output_dir/Codevisor-$suffix.dmg" "$suffix"
}

# The variants touch disjoint directories and outputs, so copy, thinning,
# signing, ZIP compression, and DMG creation can all run in parallel.
make_variant "arm64" "arm64" "darwin-x64" &
arm_variant_pid=$!
make_variant "x86_64" "x64" "darwin-arm64" &
x64_variant_pid=$!
variant_failed=0
if ! wait "$arm_variant_pid"; then
  variant_failed=1
fi
if ! wait "$x64_variant_pid"; then
  variant_failed=1
fi
if [[ "$variant_failed" != 0 ]]; then
  echo "error: one or more architecture variants failed to package" >&2
  exit 1
fi
finish_phase "Per-architecture artifact packaging"

if [[ ${#notary_args[@]} -gt 0 ]]; then
  submit_for_notarization_to_file "$output_dir/Codevisor-macOS-arm64.zip" "$notary_work/arm-zip.id" "Codevisor-macOS-arm64.zip" &
  notary_pids+=("$!")
  submit_for_notarization_to_file "$output_dir/Codevisor-arm64.dmg" "$notary_work/arm-dmg.id" "Codevisor-arm64.dmg" &
  notary_pids+=("$!")
  submit_for_notarization_to_file "$output_dir/Codevisor-macOS-x64.zip" "$notary_work/x64-zip.id" "Codevisor-macOS-x64.zip" &
  notary_pids+=("$!")
  submit_for_notarization_to_file "$output_dir/Codevisor-x64.dmg" "$notary_work/x64-dmg.id" "Codevisor-x64.dmg" &
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
  x64_zip_submission="$(<"$notary_work/x64-zip.id")"
  x64_dmg_submission="$(<"$notary_work/x64-dmg.id")"
  finish_phase "Notarization submissions"

  wait_for_notarization "$arm_zip_submission" "Codevisor-macOS-arm64.zip"
  xcrun stapler staple "$split_work/arm64/Codevisor.app"
  rm -f "$output_dir/Codevisor-macOS-arm64.zip"
  ditto --norsrc -c -k --keepParent "$split_work/arm64/Codevisor.app" "$output_dir/Codevisor-macOS-arm64.zip"

  wait_for_notarization "$x64_zip_submission" "Codevisor-macOS-x64.zip"
  xcrun stapler staple "$split_work/x64/Codevisor.app"
  rm -f "$output_dir/Codevisor-macOS-x64.zip"
  ditto --norsrc -c -k --keepParent "$split_work/x64/Codevisor.app" "$output_dir/Codevisor-macOS-x64.zip"

  wait_for_notarization "$arm_dmg_submission" "Codevisor-arm64.dmg"
  xcrun stapler staple "$output_dir/Codevisor-arm64.dmg"
  wait_for_notarization "$x64_dmg_submission" "Codevisor-x64.dmg"
  xcrun stapler staple "$output_dir/Codevisor-x64.dmg"
  finish_phase "Notarization waits, stapling, and final ZIPs"
fi

artifacts=(
  "$output_dir/Codevisor-macOS-arm64.zip"
  "$output_dir/Codevisor-macOS-x64.zip"
  "$output_dir/Codevisor-arm64.dmg"
  "$output_dir/Codevisor-x64.dmg"
)
for artifact in "${artifacts[@]}"; do
  shasum -a 256 "$artifact" | awk '{print $1}' > "$artifact.sha256"
done
finish_phase "Artifact checksums"
echo "Release timing: macOS app archive completed in $((SECONDS - release_started_at))s total"
echo "$output_dir/Codevisor-macOS-arm64.zip"

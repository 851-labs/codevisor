#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

usage() {
  cat >&2 <<'EOF'
usage: scripts/release/build-macos-app.sh <version> <output-dir>

Builds HerdMan.app, bundles the local server runtime into
Contents/Resources/server, optionally signs/notarizes the app, and writes
HerdMan-macOS.zip for the Homebrew cask.

Optional environment:
  APPLE_CODESIGN_IDENTITY       Developer ID Application identity, or empty for ad-hoc signing.
  APPLE_ID                      Apple ID used for notarization.
  APPLE_APP_SPECIFIC_PASSWORD   App-specific password for notarytool.
  APPLE_TEAM_ID                 Apple team id for notarytool.
  APP_STORE_CONNECT_API_KEY_PATH
                                Path to App Store Connect API key .p8 for notarization.
  APP_STORE_CONNECT_API_KEY_ID  App Store Connect API key id for notarization.
  APP_STORE_CONNECT_ISSUER_ID   App Store Connect issuer id for notarization.
  HERDMAN_XCODE_SCHEME          Defaults to HerdMan.
  HERDMAN_BUILD_NUMBER          Defaults to GITHUB_RUN_NUMBER or 1.
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
scheme="${HERDMAN_XCODE_SCHEME:-HerdMan}"
build_number="${HERDMAN_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
derived_data="$repo_root/dist/release/DerivedData"
runtime_dir="$repo_root/dist/release/work/app-server-runtime"
archive_path="$output_dir/HerdMan-macOS.zip"

mkdir -p "$output_dir"
(cd "$repo_root" && bun run build)
"$script_dir/build-server-runtime.sh" "$version" "$runtime_dir"

rm -rf "$derived_data"
xcode_args=(
  -project "$repo_root/apps/macos/HerdMan.xcodeproj" \
  -scheme "$scheme" \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGNING_ALLOWED=NO
)

ghostty_library="$repo_root/apps/macos/Frameworks/GhosttyKit.xcframework/macos-arm64/libghostty-internal-fat.a"
if [[ -f "$ghostty_library" ]]; then
  echo "Building with GhosttyKit from $ghostty_library"
else
  echo "GhosttyKit.xcframework not found; building with the placeholder terminal backend."
  xcode_args+=(OTHER_LDFLAGS="" SWIFT_INCLUDE_PATHS="")
fi

xcodebuild "${xcode_args[@]}" build

app_path="$derived_data/Build/Products/Release/HerdMan.app"
if [[ ! -d "$app_path" ]]; then
  echo "error: HerdMan.app was not produced at $app_path" >&2
  exit 1
fi

server_resources="$app_path/Contents/Resources/server"
rm -rf "$server_resources"
mkdir -p "$server_resources"
cp -R "$runtime_dir/." "$server_resources/"
find "$app_path" -name "._*" -delete

identity="${APPLE_CODESIGN_IDENTITY:-}"
if [[ -n "$identity" ]]; then
  while IFS= read -r -d '' candidate; do
    if file -b "$candidate" | grep -q "Mach-O"; then
      codesign --force --options runtime --timestamp --sign "$identity" "$candidate"
    fi
  done < <(find "$server_resources" -type f -print0)
  codesign --force --deep --options runtime --timestamp --sign "$identity" "$app_path"
else
  while IFS= read -r -d '' candidate; do
    if file -b "$candidate" | grep -q "Mach-O"; then
      codesign --force --sign - "$candidate"
    fi
  done < <(find "$server_resources" -type f -print0)
  codesign --force --deep --sign - "$app_path"
fi

rm -f "$archive_path"
ditto --norsrc -c -k --keepParent "$app_path" "$archive_path"

if [[ -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" && -n "${APP_STORE_CONNECT_API_KEY_ID:-}" && -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
  xcrun notarytool submit "$archive_path" \
    --key "$APP_STORE_CONNECT_API_KEY_PATH" \
    --key-id "$APP_STORE_CONNECT_API_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
    --wait
  xcrun stapler staple "$app_path"
  rm -f "$archive_path"
  ditto --norsrc -c -k --keepParent "$app_path" "$archive_path"
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  xcrun notarytool submit "$archive_path" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
  xcrun stapler staple "$app_path"
  rm -f "$archive_path"
  ditto --norsrc -c -k --keepParent "$app_path" "$archive_path"
fi

shasum -a 256 "$archive_path" | awk '{print $1}' > "$archive_path.sha256"
echo "$archive_path"

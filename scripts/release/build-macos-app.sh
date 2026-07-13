#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

usage() {
  cat >&2 <<'EOF'
usage: scripts/release/build-macos-app.sh <version> <output-dir>

Builds Codevisor.app, bundles the local server runtime into
Contents/Resources/server, optionally signs/notarizes the app, and writes
Codevisor-macOS.zip for the Homebrew cask.

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
  CODEVISOR_DARWIN_ARM64_RUNTIME_ARCHIVE
                                Optional prebuilt darwin-arm64 server runtime tarball.
  CODEVISOR_DARWIN_X64_RUNTIME_ARCHIVE
                                Optional prebuilt darwin-x64 server runtime tarball.
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
scheme="${CODEVISOR_XCODE_SCHEME:-Codevisor}"
build_number="${CODEVISOR_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
derived_data="$repo_root/dist/release/DerivedData"
runtime_root="$repo_root/dist/release/work/app-server-runtimes"
archive_path="$output_dir/Codevisor-macOS.zip"
node_entitlements="$script_dir/node-entitlements.plist"
host_target="$("$script_dir/detect-target.sh")"

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

  if [[ "$target" == "$host_target" ]]; then
    "$script_dir/build-server-runtime.sh" "$version" "$destination" "$target"
  elif [[ -n "$archive" ]]; then
    if [[ ! -f "$archive" ]]; then
      echo "error: server runtime archive for $target does not exist: $archive" >&2
      exit 1
    fi
    tar -C "$destination" -xzf "$archive"
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
prepare_server_runtime "darwin-x64"

rm -rf "$derived_data"
xcode_args=(
  -project "$repo_root/apps/macos/Codevisor.xcodeproj" \
  -scheme "$scheme" \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO
)

ghostty_framework="$repo_root/apps/macos/Frameworks/GhosttyKit.xcframework"
ghostty_library=""
# Note: `lipo -verify_arch` only accepts a single architecture in newer Xcode
# toolchains (passing two mis-parses and always fails), so check the slice
# list from `lipo -archs` instead.
library_has_arch() {
  lipo -archs "$1" 2>/dev/null | tr " " "\n" | grep -qx "$2"
}
while IFS= read -r candidate; do
  lipo -info "$candidate" || true
  if library_has_arch "$candidate" arm64 && library_has_arch "$candidate" x86_64; then
    ghostty_library="$candidate"
    break
  fi
done < <(find "$ghostty_framework" -name "*.a" -type f -print 2>/dev/null | sort)
ghostty_slice_dir="$(dirname "$ghostty_library")"
ghostty_headers="$ghostty_slice_dir/Headers/ghostty.h"
ghostty_resources="$repo_root/apps/macos/Codevisor/Resources/ghostty-resources.tar.gz"
if [[ -z "$ghostty_library" || ! -f "$ghostty_library" ]]; then
  echo "error: GhosttyKit must include a universal macOS static library with arm64 and x86_64 slices." >&2
  exit 1
fi
if [[ ! -f "$ghostty_headers" ]]; then
  echo "error: GhosttyKit headers are required at $ghostty_headers" >&2
  exit 1
fi
if [[ ! -f "$ghostty_resources" ]]; then
  echo "error: Ghostty runtime resources are required at $ghostty_resources" >&2
  exit 1
fi
echo "Building with GhosttyKit from $ghostty_library"

ghostty_link_flags=(
  "-force_load"
  "$ghostty_library"
  "-lc++"
  "-framework" "Metal"
  "-framework" "MetalKit"
  "-framework" "QuartzCore"
  "-framework" "CoreText"
  "-framework" "CoreGraphics"
  "-framework" "CoreVideo"
  "-framework" "IOSurface"
  "-framework" "IOKit"
  "-framework" "Carbon"
  "-framework" "AppKit"
  "-framework" "Foundation"
  "-framework" "CoreFoundation"
  "-framework" "Security"
  "-framework" "ApplicationServices"
  "-framework" "AudioToolbox"
  "-framework" "UniformTypeIdentifiers"
  "-framework" "GameController"
  "-framework" "Combine"
)

xcodebuild "${xcode_args[@]}" \
  OTHER_LDFLAGS="${ghostty_link_flags[*]}" \
  SWIFT_INCLUDE_PATHS="$ghostty_slice_dir/Headers" \
  build

app_path="$derived_data/Build/Products/Release/Codevisor.app"
if [[ ! -d "$app_path" ]]; then
  echo "error: Codevisor.app was not produced at $app_path" >&2
  exit 1
fi

plist_path="$app_path/Contents/Info.plist"
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
find "$app_path" -name "._*" -delete

identity="${APPLE_CODESIGN_IDENTITY:-}"
if [[ -n "$identity" ]]; then
  while IFS= read -r -d '' candidate; do
    if file -b "$candidate" | grep -q "Mach-O"; then
      if [[ "$candidate" == "$server_resources"/*/bin/node ]]; then
        codesign --force --options runtime --timestamp --entitlements "$node_entitlements" --sign "$identity" "$candidate"
      else
        codesign --force --options runtime --timestamp --sign "$identity" "$candidate"
      fi
    fi
  done < <(find "$server_resources" -type f -print0)
  codesign --force --options runtime --timestamp --sign "$identity" "$app_path"
else
  while IFS= read -r -d '' candidate; do
    if file -b "$candidate" | grep -q "Mach-O"; then
      if [[ "$candidate" == "$server_resources"/*/bin/node ]]; then
        codesign --force --entitlements "$node_entitlements" --sign - "$candidate"
      else
        codesign --force --sign - "$candidate"
      fi
    fi
  done < <(find "$server_resources" -type f -print0)
  codesign --force --sign - "$app_path"
fi

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

# DMG for direct download from www.codevisor.dev (installs without Homebrew).
# The app inside is already notarized and stapled; the image is signed and
# notarized as well so Gatekeeper accepts it straight from a browser download.
dmg_path="$output_dir/Codevisor.dmg"
dmg_root="$repo_root/dist/release/work/dmg-root"
rm -rf "$dmg_root" "$dmg_path"
mkdir -p "$dmg_root"
ditto "$app_path" "$dmg_root/Codevisor.app"
ln -s /Applications "$dmg_root/Applications"
hdiutil create -volname "Codevisor" -srcfolder "$dmg_root" -fs HFS+ -format UDZO -ov "$dmg_path"

if [[ -n "${APPLE_CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$APPLE_CODESIGN_IDENTITY" "$dmg_path"
fi

if [[ -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" && -n "${APP_STORE_CONNECT_API_KEY_ID:-}" && -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
  xcrun notarytool submit "$dmg_path" \
    --key "$APP_STORE_CONNECT_API_KEY_PATH" \
    --key-id "$APP_STORE_CONNECT_API_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
    --wait
  xcrun stapler staple "$dmg_path"
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  xcrun notarytool submit "$dmg_path" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
  xcrun stapler staple "$dmg_path"
fi

shasum -a 256 "$dmg_path" | awk '{print $1}' > "$dmg_path.sha256"
echo "$archive_path"

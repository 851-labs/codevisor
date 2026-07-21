#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: scripts/release/build-macos-xcode.sh <version> <derived-data-dir>

Builds the unsigned universal Codevisor.app into the supplied DerivedData
directory. Existing DerivedData is intentionally preserved so CI can restore
incremental Xcode and Swift package build products.

Optional environment:
  CODEVISOR_XCODE_SCHEME  Defaults to Codevisor.
  CODEVISOR_BUILD_NUMBER Defaults to GITHUB_RUN_NUMBER or 1.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

version="${1:-}"
derived_data="${2:-}"
if [[ -z "$version" || -z "$derived_data" ]]; then
  usage
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
scheme="${CODEVISOR_XCODE_SCHEME:-Codevisor}"
build_number="${CODEVISOR_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"

xcode_args=(
  -project "$repo_root/apps/macos/Codevisor.xcodeproj"
  -scheme "$scheme"
  -configuration Release
  -derivedDataPath "$derived_data"
  MARKETING_VERSION="$version"
  CURRENT_PROJECT_VERSION="$build_number"
  CODE_SIGNING_ALLOWED=NO
  ARCHS="arm64 x86_64"
  ONLY_ACTIVE_ARCH=NO
)

ghostty_framework="$repo_root/apps/macos/Frameworks/GhosttyKit.xcframework"
ghostty_library=""
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

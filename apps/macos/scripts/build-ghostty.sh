#!/usr/bin/env bash
set -euo pipefail

MACOS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$MACOS_ROOT/../.." && pwd)"
GHOSTTY_DIR="$REPO_ROOT/.repos/ghostty"
DEST_DIR="$MACOS_ROOT/Frameworks"
GHOSTTY_REPOSITORY="${GHOSTTY_REPOSITORY:-https://github.com/ghostty-org/ghostty.git}"

GHOSTTY_REF="b40acce58dcf77df52231c3798ea58e924647c89"
LIBGHOSTTY_SPM_REF="408c0616d2535f82d5e87535556715247b4aefca"
LIBGHOSTTY_SPM_RELEASE_URL="https://github.com/Lakr233/libghostty-spm/releases/download/upstream.b40acce58dcf/GhosttyKit.xcframework.zip"
LIBGHOSTTY_SPM_RELEASE_SHA256="f1dd284146c34e813a4fcd8b59c6e134298acbb776e93b901b444c13a1d74b23"

SLICES=(macos-arm64_x86_64 ios-arm64 ios-arm64_x86_64-simulator)
REPACKAGE_VERSION=2

FINGERPRINT="$({
  printf '%s\n' "$LIBGHOSTTY_SPM_REF" "$LIBGHOSTTY_SPM_RELEASE_SHA256" "$REPACKAGE_VERSION" "${SLICES[@]}"
} | /usr/bin/shasum -a 256 | cut -c1-16)"
STAMP="${GHOSTTY_REF}-${FINGERPRINT}"

case "${1:-}" in
  --print-stamp)
    echo "$STAMP"
    exit 0
    ;;
  --fetch-only)
    CURRENT_GHOSTTY_REF="$(git -C "$GHOSTTY_DIR" rev-parse HEAD 2>/dev/null || true)"
    if [[ ! -f "$GHOSTTY_DIR/build.zig" || "$CURRENT_GHOSTTY_REF" != "$GHOSTTY_REF" ]]; then
      echo "Fetching Ghostty source $GHOSTTY_REF from $GHOSTTY_REPOSITORY"
      if [[ ! -e "$GHOSTTY_DIR/.git" ]]; then
        mkdir -p "$(dirname "$GHOSTTY_DIR")"
        rm -rf "$GHOSTTY_DIR"
        git clone --filter=blob:none --no-checkout "$GHOSTTY_REPOSITORY" "$GHOSTTY_DIR"
      fi
      git -C "$GHOSTTY_DIR" fetch --depth 1 origin "$GHOSTTY_REF"
      git -C "$GHOSTTY_DIR" checkout --force --detach FETCH_HEAD
    fi
    exit 0
    ;;
  "") ;;
  *)
    echo "usage: $0 [--fetch-only|--print-stamp]" >&2
    exit 2
    ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Downloading GhosttyKit (ghostty@${GHOSTTY_REF:0:12}, libghostty-spm patches)"
curl --fail --location --silent --show-error --retry 3 \
  --output "$work/GhosttyKit.xcframework.zip" "$LIBGHOSTTY_SPM_RELEASE_URL"
actual="$(/usr/bin/shasum -a 256 "$work/GhosttyKit.xcframework.zip" | awk '{print $1}')"
if [[ "$actual" != "$LIBGHOSTTY_SPM_RELEASE_SHA256" ]]; then
  echo "error: GhosttyKit release checksum mismatch: expected $LIBGHOSTTY_SPM_RELEASE_SHA256, got $actual" >&2
  exit 1
fi
/usr/bin/ditto -x -k "$work/GhosttyKit.xcframework.zip" "$work/release"
SRC="$work/release/GhosttyKit.xcframework"

OUT="$work/GhosttyKit.xcframework"
xcodebuild_args=()
for slice in "${SLICES[@]}"; do
  library="$SRC/$slice/libghostty.a"
  header="$SRC/$slice/Headers/libghostty/ghostty.h"
  if [[ ! -f "$library" || ! -f "$header" ]]; then
    echo "error: the release has no $slice slice" >&2
    exit 1
  fi
  mkdir -p "$work/slices/$slice/Headers/GhosttyKit"
  cp "$library" "$work/slices/$slice/ghostty-internal.a"
  cp "$header" "$work/slices/$slice/Headers/GhosttyKit/ghostty.h"
  cat > "$work/slices/$slice/Headers/GhosttyKit/module.modulemap" <<'MODULEMAP'
module GhosttyKit {
    umbrella header "ghostty.h"
    export *
}
MODULEMAP
  xcodebuild_args+=(-library "$work/slices/$slice/ghostty-internal.a" -headers "$work/slices/$slice/Headers")
done
xcodebuild -create-xcframework "${xcodebuild_args[@]}" -output "$OUT" >/dev/null

MACOS_LIBRARY="$OUT/macos-arm64_x86_64/ghostty-internal.a"
if [[ ! -f "$MACOS_LIBRARY" ]]; then
  echo "error: repackaged GhosttyKit is missing its universal macOS slice." >&2
  exit 1
fi
MACOS_ARCHS="$(lipo -archs "$MACOS_LIBRARY")"
for REQUIRED_ARCH in arm64 x86_64; do
  if [[ " $MACOS_ARCHS " != *" $REQUIRED_ARCH "* ]]; then
    echo "error: GhosttyKit macOS library is missing $REQUIRED_ARCH (found: $MACOS_ARCHS)." >&2
    exit 1
  fi
done

EXPORTED_SYMBOLS="$(/usr/bin/nm -gU "$MACOS_LIBRARY" 2>/dev/null)"
for SYMBOL in _ghostty_surface_write_buffer _ghostty_surface_write_buffer_replay _ghostty_surface_process_exit; do
  if ! grep -q " T $SYMBOL$" <<<"$EXPORTED_SYMBOLS"; then
    echo "error: GhosttyKit does not export $SYMBOL (host-managed I/O patch missing)." >&2
    exit 1
  fi
done

LIBCPP_HASH_MEMORY_SYMBOL="__ZNSt3__113__hash_memoryEPKvm"
if /usr/bin/nm -u "$MACOS_LIBRARY" | grep -F "$LIBCPP_HASH_MEMORY_SYMBOL" >/dev/null; then
  echo "error: GhosttyKit imports libc++ __hash_memory and will not launch on macOS 26.2." >&2
  exit 1
fi

if strings "$MACOS_LIBRARY" | grep -c "sentry-init" >/dev/null; then
  echo "error: GhosttyKit contains sentry-native (sentry-init)." >&2
  exit 1
fi

printf '%s\n' "$STAMP" > "$OUT/.codevisor-stamp"
mkdir -p "$DEST_DIR"
rm -rf "$DEST_DIR/GhosttyKit.xcframework"
cp -R "$OUT" "$DEST_DIR/"
echo "Installed GhosttyKit.xcframework in $DEST_DIR (stamp $STAMP)"

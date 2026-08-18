#!/usr/bin/env bash
#
# Builds GhosttyKit.xcframework from the vendored Ghostty source and copies it
# next to the app for linking. Codevisor requires the real libghostty-backed
# terminal; app and release builds should fail if this framework is missing.
#
# Requirements:
#   - Zig 0.16.0 (the pinned Ghostty revision's required version).
#
# Usage:
#   apps/macos/scripts/build-ghostty.sh --fetch-only
#   nix develop ./.repos/ghostty -c apps/macos/scripts/build-ghostty.sh
set -euo pipefail

MACOS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$MACOS_ROOT/../.." && pwd)"
GHOSTTY_DIR="$REPO_ROOT/.repos/ghostty"
DEST_DIR="$MACOS_ROOT/Frameworks"
GHOSTTY_REPOSITORY="${GHOSTTY_REPOSITORY:-https://github.com/ghostty-org/ghostty.git}"
GHOSTTY_REF="${GHOSTTY_REF:-951a03b58bf60e73d2d361ac8848cb9423c8be26}"
GHOSTTY_COMPAT_PATCH="$MACOS_ROOT/patches/ghostty-libcpp-availability.patch"
FETCH_ONLY=0

# -Dsentry=false: libghostty's sentry-native init races ghostty_init's
# ensureLocale — the sentry-init thread iterates `environ` (environMap) while
# the main thread mutates it with setenv/unsetenv, segfaulting the app at
# launch (EXC_BAD_ACCESS on thread "sentry-init", wild addresses). Codevisor
# never collects ghostty's local crash dumps (the app has its own crash
# reporting), so dropping the thread costs nothing and removes the race.
BUILD_FLAGS=(
  -Demit-xcframework=true
  -Dxcframework-target=universal
  -Demit-macos-app=false
  -Dsentry=false
  -Doptimize=ReleaseFast
)

# Identifies a built framework: pinned ref + build flags. Written into the
# xcframework on install; `dev.mjs` refuses to reuse or copy a framework
# whose stamp doesn't match, so a build-script change (new ref, new flags)
# invalidates every prebuilt copy instead of silently shipping stale ones.
BUILD_FINGERPRINT="$({
  printf '%s\n' "${BUILD_FLAGS[@]}"
  /usr/bin/shasum -a 256 "$GHOSTTY_COMPAT_PATCH"
} | /usr/bin/shasum -a 256 | cut -c1-16)"
STAMP="${GHOSTTY_REF}-${BUILD_FINGERPRINT}"

if [[ "${1:-}" == "--print-stamp" ]]; then
  echo "$STAMP"
  exit 0
fi
if [[ "${1:-}" == "--fetch-only" ]]; then
  FETCH_ONLY=1
  shift
fi
if [[ $# -gt 0 ]]; then
  echo "usage: $0 [--fetch-only|--print-stamp]" >&2
  exit 2
fi

if [[ ! -f "$GHOSTTY_DIR/build.zig" ]]; then
  echo "Fetching Ghostty source $GHOSTTY_REF from $GHOSTTY_REPOSITORY"
  mkdir -p "$(dirname "$GHOSTTY_DIR")"
  rm -rf "$GHOSTTY_DIR"
  git clone --filter=blob:none --no-checkout "$GHOSTTY_REPOSITORY" "$GHOSTTY_DIR"
  git -C "$GHOSTTY_DIR" fetch --depth 1 origin "$GHOSTTY_REF"
  git -C "$GHOSTTY_DIR" checkout --detach FETCH_HEAD
fi

if [[ "$FETCH_ONLY" == 1 ]]; then
  exit 0
fi

ACTUAL_GHOSTTY_REF="$(git -C "$GHOSTTY_DIR" rev-parse HEAD)"
if [[ "$ACTUAL_GHOSTTY_REF" != "$GHOSTTY_REF" ]]; then
  echo "error: Ghostty source is at $ACTUAL_GHOSTTY_REF; expected pinned ref $GHOSTTY_REF." >&2
  exit 1
fi

if [[ ! -f "$GHOSTTY_COMPAT_PATCH" ]]; then
  echo "error: Ghostty compatibility patch not found at $GHOSTTY_COMPAT_PATCH." >&2
  exit 1
fi

if ! command -v zig >/dev/null 2>&1; then
  echo "error: zig not found on PATH. Install Zig 0.16.0 (https://ziglang.org/download/)." >&2
  exit 1
fi

ZIG_VERSION="$(zig version)"
if [[ "$ZIG_VERSION" != 0.16.0* ]]; then
  echo "warning: Ghostty requires Zig 0.16.0; found $ZIG_VERSION. The build may be rejected." >&2
fi

echo "Building GhosttyKit.xcframework (this takes a while)…"
cd "$GHOSTTY_DIR"
rm -rf "$GHOSTTY_DIR/macos/GhosttyKit.xcframework" "$GHOSTTY_DIR/zig-out"

# Keep the vendored reference checkout pristine: apply the small build-only
# compatibility patch for this invocation, then reverse it even if Zig fails.
PATCH_APPLIED=0
restore_ghostty_sources() {
  if [[ "$PATCH_APPLIED" == 1 ]]; then
    git -C "$GHOSTTY_DIR" apply --reverse "$GHOSTTY_COMPAT_PATCH"
    PATCH_APPLIED=0
  fi
}
trap restore_ghostty_sources EXIT INT TERM
if ! git -C "$GHOSTTY_DIR" apply --check "$GHOSTTY_COMPAT_PATCH"; then
  echo "error: Ghostty compatibility patch does not apply cleanly to $GHOSTTY_REF." >&2
  exit 1
fi
git -C "$GHOSTTY_DIR" apply "$GHOSTTY_COMPAT_PATCH"
PATCH_APPLIED=1

set +e
zig build "${BUILD_FLAGS[@]}"
BUILD_STATUS=$?
set -e
restore_ghostty_sources
trap - EXIT INT TERM

# Ghostty installs the framework under macos/ for its own Xcode project.
SRC="$GHOSTTY_DIR/macos/GhosttyKit.xcframework"
if [[ ! -d "$SRC" ]]; then
  # Fall back to the zig install prefix.
  SRC="$(find "$GHOSTTY_DIR/zig-out" -maxdepth 3 -name GhosttyKit.xcframework -type d | head -1 || true)"
fi
if [[ -z "${SRC:-}" || ! -d "$SRC" ]]; then
  echo "error: GhosttyKit.xcframework not found after build." >&2
  exit 1
fi

# The pinned Zig 0.16 migration currently reports a later, unrelated lib-vt
# install failure with Xcode 27 after successfully producing GhosttyKit. Only
# accept that non-zero status when a fresh universal macOS framework validates.
MACOS_SLICE="$SRC/macos-arm64_x86_64"
MACOS_LIBRARY="$MACOS_SLICE/ghostty-internal.a"
if ! plutil -lint "$SRC/Info.plist" >/dev/null; then
  echo "error: generated GhosttyKit.xcframework has an invalid Info.plist." >&2
  exit 1
fi
if [[ ! -d "$MACOS_SLICE/Headers" || ! -f "$MACOS_LIBRARY" ]]; then
  echo "error: generated GhosttyKit.xcframework is missing its universal macOS slice." >&2
  exit 1
fi
MACOS_ARCHS="$(lipo -archs "$MACOS_LIBRARY")"
for REQUIRED_ARCH in arm64 x86_64; do
  if [[ " $MACOS_ARCHS " != *" $REQUIRED_ARCH "* ]]; then
    echo "error: generated GhosttyKit macOS library is missing $REQUIRED_ARCH (found: $MACOS_ARCHS)." >&2
    exit 1
  fi
done
if [[ "$BUILD_STATUS" -ne 0 ]]; then
  echo "warning: Ghostty's aggregate build exited $BUILD_STATUS after producing a valid GhosttyKit.xcframework." >&2
fi

# A libc++ header newer than the deployment runtime can otherwise introduce
# this unresolved LLVM 21 symbol. macOS 26.2's libc++.1.dylib does not export
# it, so dyld would abort before Codevisor reaches main.
LIBCPP_HASH_MEMORY_SYMBOL="__ZNSt3__113__hash_memoryEPKvm"
if /usr/bin/nm -u "$MACOS_LIBRARY" | grep -F "$LIBCPP_HASH_MEMORY_SYMBOL" >/dev/null; then
  echo "error: generated GhosttyKit imports libc++ __hash_memory and will not launch on macOS 26.2." >&2
  exit 1
fi

# -Dsentry=false must actually hold in the produced binary: a framework with
# sentry-native compiled in reintroduces the launch crash the flag removes.
if strings "$MACOS_LIBRARY" | grep -q "sentry-init"; then
  echo "error: generated GhosttyKit still contains sentry-native (sentry-init). Check -Dsentry=false." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
rm -rf "$DEST_DIR/GhosttyKit.xcframework"
cp -R "$SRC" "$DEST_DIR/"
printf '%s\n' "$STAMP" > "$DEST_DIR/GhosttyKit.xcframework/.codevisor-stamp"
echo "Copied GhosttyKit.xcframework to $DEST_DIR (stamp $STAMP)"
echo "Next: verify the Codevisor app target build settings still point at this framework."

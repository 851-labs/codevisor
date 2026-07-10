#!/usr/bin/env bash
#
# Builds GhosttyKit.xcframework from the vendored Ghostty source and copies it
# next to the app for linking. HerdMan requires the real libghostty-backed
# terminal; app and release builds should fail if this framework is missing.
#
# Requirements:
#   - Zig 0.15.2 (Ghostty pins this exact version in build.zig).
#   - A STABLE macOS SDK. NOTE: Zig 0.15.2 cannot link against the macOS 26/27
#     *beta* SDK (its libSystem.tbd lacks the plain arm64 slice), so build this
#     on a machine with a released SDK, or once Zig supports the beta SDK.
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
GHOSTTY_REF="${GHOSTTY_REF:-28f9367bee11ad42f40f8aa589eb8c6db62d34be}"
FETCH_ONLY=0

if [[ "${1:-}" == "--fetch-only" ]]; then
  FETCH_ONLY=1
  shift
fi
if [[ $# -gt 0 ]]; then
  echo "usage: $0 [--fetch-only]" >&2
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

if ! command -v zig >/dev/null 2>&1; then
  echo "error: zig not found on PATH. Install Zig 0.15.2 (https://ziglang.org/download/)." >&2
  exit 1
fi

ZIG_VERSION="$(zig version)"
if [[ "$ZIG_VERSION" != 0.15.2* ]]; then
  echo "warning: Ghostty requires Zig 0.15.2; found $ZIG_VERSION. The build may be rejected." >&2
fi

echo "Building GhosttyKit.xcframework (this takes a while)…"
cd "$GHOSTTY_DIR"
zig build \
  -Demit-xcframework=true \
  -Dxcframework-target=universal \
  -Demit-macos-app=false \
  -Doptimize=ReleaseFast

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

mkdir -p "$DEST_DIR"
rm -rf "$DEST_DIR/GhosttyKit.xcframework"
cp -R "$SRC" "$DEST_DIR/"
echo "Copied GhosttyKit.xcframework to $DEST_DIR"
echo "Next: verify the HerdMan app target build settings still point at this framework."

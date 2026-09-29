#!/usr/bin/env bash
#
# Builds libghostty-vt as WebAssembly for the server's terminal state
# (packages/terminal/resources/ghostty-vt.wasm) from a pinned Ghostty
# revision. The output is checked in; rerun this after bumping the pin and
# commit both files.
#
# Requirements: Zig 0.16.0 on PATH (or ZIG=/path/to/zig), git.
#
# Usage: scripts/build-ghostty-vt-wasm.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES="$REPO_ROOT/packages/terminal/resources"
REF_FILE="$RESOURCES/GHOSTTY-VT-REF"
GHOSTTY_REF="$(tr -d '[:space:]' < "$REF_FILE")"
GHOSTTY_REPOSITORY="${GHOSTTY_REPOSITORY:-https://github.com/ghostty-org/ghostty.git}"
ZIG="${ZIG:-zig}"

zig_version="$("$ZIG" version)"
if [[ "$zig_version" != "0.16.0" ]]; then
  echo "error: Zig 0.16.0 required (found $zig_version)" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git -C "$work" init -q ghostty
git -C "$work/ghostty" remote add origin "$GHOSTTY_REPOSITORY"
git -C "$work/ghostty" fetch -q --depth 1 origin "$GHOSTTY_REF"
git -C "$work/ghostty" checkout -q FETCH_HEAD

(
  cd "$work/ghostty"
  "$ZIG" build \
    -Demit-lib-vt \
    -Dtarget=wasm32-freestanding \
    -Doptimize=ReleaseSmall \
    -p "$work/out"
)

cp "$work/out/bin/ghostty-vt.wasm" "$RESOURCES/ghostty-vt.wasm"
echo "Built $RESOURCES/ghostty-vt.wasm from ghostty@$GHOSTTY_REF"

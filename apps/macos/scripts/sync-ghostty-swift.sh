#!/usr/bin/env bash
# Re-syncs the vendored Ghostty Swift surface layer from references/ghostty.
#
# Copies the manifest files verbatim over apps/macos/HerdMan/Vendor/GhosttySwift
# and prints the resulting git diff stat. HERDMAN-PATCH blocks are clobbered by
# this copy ON PURPOSE — re-apply them by hand afterwards (see UPSTREAM.md;
# `grep -rn HERDMAN-PATCH` on the previous commit shows every patch).
#
# The vendored Swift layer must match the commit GhosttyKit.xcframework is
# built from (GHOSTTY_REF in build-ghostty.sh). Run build-ghostty.sh first
# when bumping the commit.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC="$REPO_ROOT/references/ghostty/macos/Sources"
DST="$REPO_ROOT/apps/macos/HerdMan/Vendor/GhosttySwift"

if [[ ! -d "$SRC" ]]; then
  echo "error: $SRC not found — run apps/macos/scripts/build-ghostty.sh --fetch-only first" >&2
  exit 1
fi

# Manifest: "upstream-relative-path -> vendor-relative-path"
MANIFEST=(
  "Ghostty/GhosttyPackageMeta.swift|Ghostty/GhosttyPackageMeta.swift"
  "Ghostty/GhosttyPackage.swift|Ghostty/GhosttyPackage.swift"
  "Ghostty/Ghostty.Action.swift|Ghostty/Ghostty.Action.swift"
  "Ghostty/Ghostty.ChildExitedMessage.swift|Ghostty/Ghostty.ChildExitedMessage.swift"
  "Ghostty/Ghostty.Command.swift|Ghostty/Ghostty.Command.swift"
  "Ghostty/Ghostty.Config.swift|Ghostty/Ghostty.Config.swift"
  "Ghostty/Ghostty.ConfigTypes.swift|Ghostty/Ghostty.ConfigTypes.swift"
  "Ghostty/Ghostty.Error.swift|Ghostty/Ghostty.Error.swift"
  "Ghostty/Ghostty.Input.swift|Ghostty/Ghostty.Input.swift"
  "Ghostty/Ghostty.Inspector.swift|Ghostty/Ghostty.Inspector.swift"
  "Ghostty/Ghostty.Shell.swift|Ghostty/Ghostty.Shell.swift"
  "Ghostty/Ghostty.Surface.swift|Ghostty/Ghostty.Surface.swift"
  "Ghostty/NSEvent+Extension.swift|Ghostty/NSEvent+Extension.swift"
  "Ghostty/Surface View/OSSurfaceView.swift|Ghostty/Surface View/OSSurfaceView.swift"
  "Ghostty/Surface View/SurfaceView_AppKit.swift|Ghostty/Surface View/SurfaceView_AppKit.swift"
  # NOTE: Ghostty/Surface View/SurfaceConfiguration.swift is an EXTRACTION from
  # upstream SurfaceView.swift (not copied here) — update it by hand from the
  # ranges documented in its header.
  "Helpers/AppInfo.swift|Helpers/AppInfo.swift"
  "Helpers/CrossKit.swift|Helpers/CrossKit.swift"
  "Helpers/Cursor.swift|Helpers/Cursor.swift"
  "Helpers/KeyboardLayout.swift|Helpers/KeyboardLayout.swift"
  "Helpers/Extensions/Array+Extension.swift|Helpers/Extensions/Array+Extension.swift"
  "Helpers/Extensions/EventModifiers+Extension.swift|Helpers/Extensions/EventModifiers+Extension.swift"
  "Helpers/Extensions/NSAppearance+Extension.swift|Helpers/Extensions/NSAppearance+Extension.swift"
  "Helpers/Extensions/NSMenuItem+Extension.swift|Helpers/Extensions/NSMenuItem+Extension.swift"
  "Helpers/Extensions/NSPasteboard+Extension.swift|Helpers/Extensions/NSPasteboard+Extension.swift"
  "Helpers/Extensions/NSScreen+Extension.swift|Helpers/Extensions/NSScreen+Extension.swift"
  "Helpers/Extensions/OSColor+Extension.swift|Helpers/Extensions/OSColor+Extension.swift"
  "Helpers/Extensions/OSPasteboard+Extension.swift|Helpers/Extensions/OSPasteboard+Extension.swift"
  "Helpers/Extensions/Optional+Extension.swift|Helpers/Extensions/Optional+Extension.swift"
  "Helpers/Extensions/UUID+Extension.swift|Helpers/Extensions/UUID+Extension.swift"
  "Helpers/Extensions/UserDefaults+Extension.swift|Helpers/Extensions/UserDefaults+Extension.swift"
  "Features/Secure Input/SecureInput.swift|Features/SecureInput.swift"
)

for entry in "${MANIFEST[@]}"; do
  src_rel="${entry%%|*}"
  dst_rel="${entry##*|}"
  mkdir -p "$DST/$(dirname "$dst_rel")"
  cp "$SRC/$src_rel" "$DST/$dst_rel"
  echo "synced: $dst_rel"
done

cp "$REPO_ROOT/references/ghostty/LICENSE" "$DST/LICENSE"

echo
echo "== diff vs HEAD (re-apply HERDMAN-PATCH blocks before committing) =="
git -C "$REPO_ROOT" diff --stat -- "$DST"

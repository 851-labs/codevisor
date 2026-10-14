#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC="$REPO_ROOT/.repos/ghostty/macos/Sources"
DST="$REPO_ROOT/apps/macos/Codevisor/Vendor/GhosttySwift"

if [[ ! -d "$SRC" ]]; then
  echo "error: $SRC not found — run apps/macos/scripts/build-ghostty.sh --fetch-only first" >&2
  exit 1
fi

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

cp "$REPO_ROOT/.repos/ghostty/LICENSE" "$DST/LICENSE"

echo
echo "== diff vs HEAD (re-apply CODEVISOR-PATCH blocks before committing) =="
git -C "$REPO_ROOT" diff --stat -- "$DST"

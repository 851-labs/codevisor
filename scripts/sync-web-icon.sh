#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
ictool="${ICTOOL:-/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool}"
source_icon="$repo_root/apps/macos/Codevisor/Resources/AppIcon.icon"
public="$repo_root/apps/www/public"

if [[ ! -x "$ictool" ]]; then
  print -u2 "error: ictool not found at $ictool"
  print -u2 "Install Xcode 27, or set ICTOOL to Icon Composer's ictool."
  exit 1
fi
if ! command -v oxipng >/dev/null; then
  print -u2 "error: oxipng not found. Install it with: brew install oxipng"
  exit 1
fi

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/CodevisorWebIcon.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT

export_icon() {
  "$ictool" "$source_icon" --export-image --output-file "$work_directory/$1.png" \
    --platform macOS --rendition Default --width "$1" --height "$1" --scale 1 \
    --design-generation 27 >/dev/null
}

full_bleed_size=256
dock_body_size=206
export_icon $full_bleed_size
export_icon $dock_body_size
swift "$repo_root/scripts/render-app-icon.swift" "$work_directory/$full_bleed_size.png" "$public/favicon.png"
swift "$repo_root/scripts/render-app-icon.swift" --dock "$work_directory/$dock_body_size.png" "$public/codevisor-icon.png"
oxipng --quiet --opt 6 --strip safe "$public/favicon.png" "$public/codevisor-icon.png"
print "Updated $public/favicon.png and $public/codevisor-icon.png from $source_icon"

"$repo_root/scripts/sync-browser-extension-icons.sh" "$public/codevisor-icon.png"

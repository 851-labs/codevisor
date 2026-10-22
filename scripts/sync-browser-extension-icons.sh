#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
source_icon="${1:-$repo_root/apps/www/public/codevisor-icon.png}"
destination="$repo_root/packages/automation/resources/browser-extension/icons"

if [[ ! -f "$source_icon" ]]; then
  print -u2 "error: source icon not found at $source_icon"
  exit 1
fi
if ! command -v oxipng >/dev/null; then
  print -u2 "error: oxipng not found. Install it with: brew install oxipng"
  exit 1
fi

source_width="$(sips -g pixelWidth "$source_icon" 2>/dev/null | awk '/pixelWidth/ { print $2 }')"
source_height="$(sips -g pixelHeight "$source_icon" 2>/dev/null | awk '/pixelHeight/ { print $2 }')"
if [[ "$source_width" != "256" || "$source_height" != "256" ]]; then
  print -u2 "error: expected a 256x256 source icon, got ${source_width}x${source_height}"
  exit 1
fi

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/CodevisorBrowserIcons.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT

sips --cropToHeightWidth 218 218 "$source_icon" \
  --out "$work_directory/source.png" >/dev/null

for size in 16 32 128; do
  sips --resampleHeightWidth "$size" "$size" "$work_directory/source.png" \
    --out "$destination/$size.png" >/dev/null
done
oxipng --quiet --opt 6 --strip safe "$destination"/{16,32,128}.png

print "Updated Chrome extension icons from $source_icon"

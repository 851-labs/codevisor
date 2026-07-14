#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
app_path="${1:-$repo_root/DerivedData/Build/Products/Release/Codevisor.app}"
source_icon="$app_path/Contents/Resources/AppIcon.icns"
destination="$repo_root/apps/www/public/codevisor-icon.png"

if [[ ! -f "$source_icon" ]]; then
  print -u2 "error: compiled app icon not found at $source_icon"
  print -u2 "Build the Release configuration first, or pass the path to Codevisor.app."
  exit 1
fi

# The ICNS is Xcode/Icon Composer's final output, so the website receives the
# exact same lighting, glass, shadow, background, and artwork sizing as the app.
sips -s format png "$source_icon" --out "$destination" >/dev/null
print "Updated $destination from $source_icon"

#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
profile="$(mktemp -d)"
trap 'rm -rf "$profile"' EXIT

render() {
  local page="$1" size="$2" output="$3"
  shift 3
  "$chrome" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --user-data-dir="$profile" --window-size="$size" --screenshot="$PWD/$output" "$@" \
    "file://$PWD/$page" 2>/dev/null
}

render screenshot-1.html 1280,800 screenshot-1.png
render screenshot-2.html 1280,800 screenshot-2.png
render small-promo-tile.html 440,280 small-promo-tile.png
render store-icon.html 128,128 store-icon.png --default-background-color=00000000

sips -g pixelWidth -g pixelHeight -g hasAlpha screenshot-1.png screenshot-2.png small-promo-tile.png store-icon.png

#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

swift_sources() {
  find apps/ios apps/macos \
    -name "*.swift" \
    -not -path "*/.build/*" \
    -not -path "*/DerivedData*/*" \
    -not -path "*/Vendor/*"
}

subfloor=$(swift_sources | xargs grep -nE '(ofSize|size): *[0-9](\.[0-9]+)? *[,)]' 2>/dev/null || true)
if [[ -n "$subfloor" ]]; then
  echo "error: font size literal below the 10 pt legibility floor (HIG minimum: 11 pt iOS / 10 pt macOS)."
  echo "Use a text style, or a token from CodevisorUI Typography:"
  echo "$subfloor"
  fail=1
fi

light=$(swift_sources | xargs grep -nE 'weight: *\.(ultraLight|thin|light)\b|fontWeight\(\.(ultraLight|thin|light)\)' 2>/dev/null || true)
if [[ -n "$light" ]]; then
  echo "error: Ultralight/Thin/Light font weights are hard to read (HIG: avoid light weights)."
  echo "$light"
  fail=1
fi

if [[ "$fail" -eq 0 ]]; then
  echo "typography check passed"
fi
exit "$fail"

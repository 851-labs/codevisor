#!/usr/bin/env bash
# Typography guardrail — enforces the HIG floors established in
# apps/macos/Packages/CodevisorUI/Sources/CodevisorUI/DesignSystem/Typography.swift
#
# Blocks:
#   1. Font size literals below the macOS 10 pt legibility floor
#      (iOS's floor is 11 pt, but 10-11 pt macOS glyph tokens are legal,
#      so the shared floor checked here is 10).
#   2. Light-family font weights (.ultraLight, .thin, .light) — HIG:
#      avoid light weights.
#
# See docs: Apple HIG "Typography" — minimum sizes per platform.
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

# First-party Swift sources only (skip SwiftPM checkouts/build products).
swift_sources() {
  find apps/ios apps/macos \
    -name "*.swift" \
    -not -path "*/.build/*" \
    -not -path "*/DerivedData*/*" \
    -not -path "*/Vendor/*"
}

# 1. Sub-floor size literals: size: 0-9 / ofSize: 0-9 (incl. fractions).
subfloor=$(swift_sources | xargs grep -nE '(ofSize|size): *[0-9](\.[0-9]+)? *[,)]' 2>/dev/null || true)
if [[ -n "$subfloor" ]]; then
  echo "error: font size literal below the 10 pt legibility floor (HIG minimum: 11 pt iOS / 10 pt macOS)."
  echo "Use a text style, or a token from CodevisorUI Typography:"
  echo "$subfloor"
  fail=1
fi

# 2. Light-family weights.
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

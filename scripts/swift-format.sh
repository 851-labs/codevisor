#!/usr/bin/env bash
# Run swift-format over first-party Swift sources.
#   scripts/swift-format.sh fix    — format in place
#   scripts/swift-format.sh check  — lint mode; non-zero exit on findings
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-check}"

files() {
  find apps packages -name "*.swift" \
    -not -path "*/Vendor/*" \
    -not -path "*/.build/*" \
    -not -path "*DerivedData*" \
    -not -path "*/tmp/*"
}

case "$mode" in
  fix)
    files | xargs swift format format --in-place --parallel
    ;;
  check)
    files | xargs swift format lint --strict --parallel
    ;;
  *)
    echo "usage: $0 [fix|check]" >&2
    exit 2
    ;;
esac

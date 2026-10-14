#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-check}"

files() {
  find apps packages -name "*.swift" \
    -not -path "*/Vendor/*" \
    -not -path "*/Generated/*" \
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

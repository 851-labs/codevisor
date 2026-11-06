#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-check}"

in_scope() {
  grep -E '^(apps|packages)/.+\.swift$' | grep -vE '/(Vendor|Generated|\.build|tmp)/|DerivedData|^packages/net/native/'
}

files() {
  find apps packages -name "*.swift" | in_scope
}

case "$mode" in
  fix)
    files | xargs swift format format --in-place --parallel
    ;;
  check)
    files | xargs swift format lint --strict --parallel
    ;;
  scope)
    in_scope
    ;;
  *)
    echo "usage: $0 [fix|check|scope]" >&2
    exit 2
    ;;
esac

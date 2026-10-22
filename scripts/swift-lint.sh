#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

baseline="$(mktemp)"
trap 'rm -f "$baseline"' EXIT
node scripts/swift-lint-baseline.mjs expand "$baseline"
swiftlint lint --quiet --strict --baseline "$baseline"

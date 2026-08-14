#!/usr/bin/env bash
# SwiftLint with the repo baseline; --strict makes any non-baselined
# violation fail. Keep "**/node_modules" in .swiftlint.yml's excluded list —
# letting SwiftLint crawl bun's per-package node_modules symlink trees
# crashes it (SIGILL).
set -euo pipefail
cd "$(dirname "$0")/.."
exec swiftlint lint --quiet --strict --baseline .swiftlint-baseline.json

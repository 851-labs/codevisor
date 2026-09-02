#!/usr/bin/env bash
# SwiftLint in strict mode: any violation fails. Keep "**/node_modules" in
# .swiftlint.yml's excluded list — letting SwiftLint crawl bun's per-package
# node_modules symlink trees crashes it (SIGILL).
set -euo pipefail
cd "$(dirname "$0")/.."

swiftlint lint --quiet --strict

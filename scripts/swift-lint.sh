#!/usr/bin/env bash
# SwiftLint with the repo baseline; --strict makes any non-baselined
# violation fail. Keep "**/node_modules" in .swiftlint.yml's excluded list —
# letting SwiftLint crawl bun's per-package node_modules symlink trees
# crashes it (SIGILL).
set -euo pipefail
cd "$(dirname "$0")/.."

# Modern SwiftLint baselines use repository-relative paths, making the checked
# baseline portable across clones and worktrees without runtime rewriting.
swiftlint lint --quiet --strict --baseline .swiftlint-baseline.json

#!/usr/bin/env bash
# SwiftLint with the repo baseline; --strict makes any non-baselined
# violation fail. Keep "**/node_modules" in .swiftlint.yml's excluded list —
# letting SwiftLint crawl bun's per-package node_modules symlink trees
# crashes it (SIGILL).
set -euo pipefail
cd "$(dirname "$0")/.."

# SwiftLint writes absolute file URLs into its baseline. The baseline is shared
# by every git worktree, so normalize those URLs to the current checkout before
# linting; otherwise every grandfathered violation is reported as new outside
# the worktree that last generated the file.
portable_baseline="$(mktemp)"
trap 'rm -f "$portable_baseline"' EXIT
node - .swiftlint-baseline.json "$portable_baseline" "$PWD" <<'NODE'
const fs = require("node:fs")
const [source, destination, root] = process.argv.slice(2)
const baseline = JSON.parse(fs.readFileSync(source, "utf8"))
for (const entry of baseline) {
  const location = entry?.violation?.location
  const file = location?.file
  if (typeof file !== "string") continue
  const marker = ["/apps/", "/packages/"].find((candidate) => file.includes(candidate))
  if (marker === undefined) continue
  location.file = `file://${root}${file.slice(file.indexOf(marker))}`
}
fs.writeFileSync(destination, JSON.stringify(baseline))
NODE

swiftlint lint --quiet --strict --baseline "$portable_baseline"

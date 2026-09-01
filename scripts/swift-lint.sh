#!/usr/bin/env bash
# SwiftLint with the repo baseline; --strict makes any non-baselined
# violation fail. Keep "**/node_modules" in .swiftlint.yml's excluded list —
# letting SwiftLint crawl bun's per-package node_modules symlink trees
# crashes it (SIGILL).
set -euo pipefail
cd "$(dirname "$0")/.."

# SwiftLint can still write absolute file URLs when regenerating a baseline.
# The baseline is shared by every git worktree, so normalize both absolute and
# repository-relative entries to this checkout before linting. Otherwise every
# grandfathered violation is reported as new outside the worktree that last
# generated the file.
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
  const marker = ["apps/", "packages/"].find((candidate) => {
    return file.startsWith(candidate) || file.includes(`/${candidate}`)
  })
  if (marker === undefined) continue
  const relative = file.startsWith(marker) ? file : file.slice(file.indexOf(`/${marker}`) + 1)
  location.file = `file://${root}/${relative}`
}
fs.writeFileSync(destination, JSON.stringify(baseline))
NODE

swiftlint lint --quiet --strict --baseline "$portable_baseline"

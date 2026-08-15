#!/usr/bin/env node
// Enforces that the max-lines grandfather list in .oxlintrc.json only ever
// shrinks. oxlint itself catches NEW oversized files; this check catches the
// other direction — a listed file that no longer exists or has dropped to the
// 500-line cap must be REMOVED from the list, so exemptions can't outlive the
// problem they grandfathered. The SwiftLint side gets the same property from
// `--strict --baseline`: baselined violations that stop matching are simply
// dead entries, and the baseline is regenerated (only ever smaller) when
// files move.
import { readFileSync, existsSync } from "node:fs"

const MAX_LINES = 500
const config = JSON.parse(readFileSync(new URL("../.oxlintrc.json", import.meta.url), "utf8"))
const override = (config.overrides ?? []).find(
  (entry) => entry.rules && entry.rules["max-lines"] === "off"
)
const files = override?.files ?? []

const stale = []
for (const file of files) {
  if (!existsSync(file)) {
    stale.push(`${file} — no longer exists`)
    continue
  }
  const lines = readFileSync(file, "utf8").split("\n").length - 1
  if (lines <= MAX_LINES) {
    stale.push(`${file} — ${lines} lines, now within the ${MAX_LINES}-line cap`)
  }
}

const sorted = [...files].sort()
const unsorted = files.some((file, index) => file !== sorted[index])

if (stale.length > 0 || unsorted) {
  if (stale.length > 0) {
    console.error("Stale max-lines grandfather entries (remove them from .oxlintrc.json):")
    for (const entry of stale) console.error(`  ${entry}`)
  }
  if (unsorted) {
    console.error("Grandfather list is not sorted — keep it sorted for reviewable diffs.")
  }
  process.exit(1)
}

console.log(
  `Size ratchet holds: ${files.length} grandfathered files, all still over ${MAX_LINES} lines.`
)

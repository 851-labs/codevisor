#!/usr/bin/env node
import { spawnSync } from "node:child_process"
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join, relative, resolve } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"

export const baselineFile = ".swiftlint-baseline.json"

const withFile = (entry, file) => ({
  ...entry,
  violation: { ...entry.violation, location: { ...entry.violation.location, file } }
})

function repoRelative(fileURL, root) {
  const path = relative(root, fileURLToPath(fileURL))
  if (path.startsWith("..")) throw new Error(`${fileURL} is outside ${root}`)
  return path
}

const entryKey = ({ violation: { location, reason } }) =>
  [location.file, String(location.line).padStart(6, "0"), reason].join("\0")

const byEntryKey = (left, right) => {
  if (entryKey(left) < entryKey(right)) return -1
  return entryKey(left) > entryKey(right) ? 1 : 0
}

export const portableBaseline = (entries, root) =>
  entries
    .map((entry) => withFile(entry, repoRelative(entry.violation.location.file, root)))
    .toSorted(byEntryKey)

export const checkoutBaseline = (entries, root) =>
  entries.map((entry) =>
    withFile(entry, pathToFileURL(join(root, entry.violation.location.file)).href)
  )

export function writeBaseline(root) {
  const scratch = mkdtempSync(join(tmpdir(), "swiftlint-baseline-"))
  try {
    const written = join(scratch, "baseline.json")
    spawnSync("swiftlint", ["lint", "--quiet", "--strict", "--write-baseline", written], {
      cwd: root,
      stdio: "ignore"
    })
    const entries = JSON.parse(readFileSync(written, "utf8"))
    const portable = portableBaseline(entries, realpathSync(root))
    writeFileSync(join(root, baselineFile), `${JSON.stringify(portable, null, 2)}\n`)
    return portable.length
  } finally {
    rmSync(scratch, { recursive: true, force: true })
  }
}

export function expandBaseline(root, destination) {
  const entries = JSON.parse(readFileSync(join(root, baselineFile), "utf8"))
  writeFileSync(destination, JSON.stringify(checkoutBaseline(entries, realpathSync(root))))
}

const repoRoot = fileURLToPath(new URL("..", import.meta.url))

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [command, destination] = process.argv.slice(2)
  if (command === "write") {
    console.log(`Wrote ${writeBaseline(repoRoot)} grandfathered violations to ${baselineFile}`)
  } else if (command === "expand" && destination !== undefined) {
    expandBaseline(repoRoot, destination)
  } else {
    throw new Error("usage: swift-lint-baseline.mjs write | expand <destination>")
  }
}

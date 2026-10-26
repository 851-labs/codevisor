#!/usr/bin/env node
import { spawnSync } from "node:child_process"
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

export const baselineFile = ".swiftlint-baseline.json"
export const minimumSwiftLintVersion = "0.65.1"

const versionParts = (version) => version.trim().split(".").map(Number)

export function supportsRelativeBaselines(version) {
  const parts = versionParts(version)
  const minimum = versionParts(minimumSwiftLintVersion)
  const differing = minimum.findIndex((part, index) => (parts[index] ?? 0) !== part)
  return differing === -1 || (parts[differing] ?? 0) > minimum[differing]
}

function requireSwiftLint() {
  const { stdout, error } = spawnSync("swiftlint", ["version"], { encoding: "utf8" })
  if (error !== undefined) throw new Error("SwiftLint is not installed: brew install swiftlint")
  if (!supportsRelativeBaselines(stdout)) {
    throw new Error(
      `SwiftLint ${stdout.trim()} writes baseline paths that ${baselineFile} can't match; ` +
        `${minimumSwiftLintVersion} or newer is required: brew upgrade swiftlint`
    )
  }
}

const entryKey = ({ violation: { location, reason } }) =>
  [location.file, String(location.line).padStart(6, "0"), reason].join("\0")

const byEntryKey = (left, right) => {
  if (entryKey(left) < entryKey(right)) return -1
  return entryKey(left) > entryKey(right) ? 1 : 0
}

const withSortedKeys = (_, value) =>
  value === null || typeof value !== "object" || Array.isArray(value)
    ? value
    : Object.fromEntries(
        Object.entries(value).toSorted(([left], [right]) => left.localeCompare(right))
      )

export function lint(root, stdio = "inherit") {
  requireSwiftLint()
  const result = spawnSync(
    "swiftlint",
    ["lint", "--quiet", "--strict", "--baseline", baselineFile],
    {
      cwd: root,
      stdio
    }
  )
  return result.status ?? 1
}

export function writeBaseline(root) {
  requireSwiftLint()
  const scratch = mkdtempSync(join(tmpdir(), "swiftlint-baseline-"))
  try {
    const written = join(scratch, "baseline.json")
    spawnSync("swiftlint", ["lint", "--quiet", "--strict", "--write-baseline", written], {
      cwd: root,
      stdio: "ignore"
    })
    const entries = JSON.parse(readFileSync(written, "utf8")).toSorted(byEntryKey)
    writeFileSync(join(root, baselineFile), `${JSON.stringify(entries, withSortedKeys, 2)}\n`)
    return entries.length
  } finally {
    rmSync(scratch, { recursive: true, force: true })
  }
}

const repoRoot = fileURLToPath(new URL("..", import.meta.url))

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [command] = process.argv.slice(2)
  if (command === "lint") {
    process.exitCode = lint(repoRoot)
  } else if (command === "write") {
    console.log(`Wrote ${writeBaseline(repoRoot)} grandfathered violations to ${baselineFile}`)
  } else {
    throw new Error("usage: swift-lint.mjs lint | write")
  }
}

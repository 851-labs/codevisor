import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

import {
  checkoutBaseline,
  expandBaseline,
  portableBaseline,
  writeBaseline
} from "./swift-lint-baseline.mjs"

const repoRoot = fileURLToPath(new URL("..", import.meta.url))
const swiftlintMissing = spawnSync("swiftlint", ["version"]).error !== undefined
const needsSwiftLint = { skip: swiftlintMissing && "SwiftLint is not installed" }

const violation = (file) => ({
  violation: { reason: "too long", location: { file, line: 3, character: 1 } },
  text: "func long() {"
})

test("a baseline written in one checkout applies in another", () => {
  const written = portableBaseline(
    [violation("file:///work/a/packages/B.swift"), violation("file:///work/a/apps/A.swift")],
    "/work/a"
  )
  assert.deepEqual(
    written.map((entry) => entry.violation.location.file),
    ["apps/A.swift", "packages/B.swift"]
  )
  assert.deepEqual(
    checkoutBaseline(written, "/work/b").map((entry) => entry.violation.location.file),
    ["file:///work/b/apps/A.swift", "file:///work/b/packages/B.swift"]
  )
})

const swiftFunction = (name, bodyLines) =>
  [
    `  static func ${name}() -> Int {`,
    "    var total = 0",
    ...Array.from({ length: bodyLines - 2 }, () => "    total += 1"),
    "    return total",
    "  }"
  ].join("\n")

function swiftPackage(t) {
  const root = mkdtempSync(join(tmpdir(), "codevisor-swiftlint-"))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  copyFileSync(join(repoRoot, ".swiftlint.yml"), join(root, ".swiftlint.yml"))
  mkdirSync(join(root, "packages"))
  writeFileSync(join(root, ".swiftlint-baseline.json"), "[]")
  return {
    write: (...functions) =>
      writeFileSync(
        join(root, "packages/Example.swift"),
        `enum Example {\n${functions.join("\n\n")}\n}\n`
      ),
    lint: () => {
      const expanded = join(root, "expanded.json")
      expandBaseline(root, expanded)
      return spawnSync("swiftlint", ["lint", "--quiet", "--strict", "--baseline", expanded], {
        cwd: root
      }).status
    },
    root
  }
}

test("functions over 50 lines fail SwiftLint", needsSwiftLint, (t) => {
  const swift = swiftPackage(t)
  swift.write(swiftFunction("short", 50))
  assert.equal(swift.lint(), 0)
  swift.write(swiftFunction("long", 51))
  assert.notEqual(swift.lint(), 0)
})

test("the baseline keeps old long functions but fails grown or new ones", needsSwiftLint, (t) => {
  const swift = swiftPackage(t)
  swift.write(swiftFunction("long", 60))
  assert.notEqual(swift.lint(), 0)
  assert.equal(writeBaseline(swift.root), 1)
  assert.equal(swift.lint(), 0)
  swift.write(swiftFunction("long", 61))
  assert.notEqual(swift.lint(), 0)
  swift.write(swiftFunction("long", 60), swiftFunction("added", 51))
  assert.notEqual(swift.lint(), 0)
})

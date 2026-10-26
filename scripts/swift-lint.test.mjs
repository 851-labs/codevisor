import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

import { baselineFile, lint, supportsRelativeBaselines, writeBaseline } from "./swift-lint.mjs"

const repoRoot = fileURLToPath(new URL("..", import.meta.url))
const swiftlintMissing = spawnSync("swiftlint", ["version"]).error !== undefined
const needsSwiftLint = { skip: swiftlintMissing && "SwiftLint is not installed" }

test("only SwiftLint releases that write relative baseline paths are accepted", () => {
  for (const version of ["0.65.1", "0.65.2", "0.66.0", "0.100.0", "1.0.0", "0.65.1\n"]) {
    assert.ok(supportsRelativeBaselines(version), version)
  }
  for (const version of ["0.65.0", "0.64.9", "0.9.0", "0.65"]) {
    assert.ok(!supportsRelativeBaselines(version), version)
  }
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
  const scratch = join(repoRoot, "tmp")
  mkdirSync(scratch, { recursive: true })
  const root = mkdtempSync(join(scratch, "swiftlint-"))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  copyFileSync(join(repoRoot, ".swiftlint.yml"), join(root, ".swiftlint.yml"))
  mkdirSync(join(root, "packages"))
  writeFileSync(join(root, baselineFile), "[]")
  return {
    write: (...functions) =>
      writeFileSync(
        join(root, "packages/Example.swift"),
        `enum Example {\n${functions.join("\n\n")}\n}\n`
      ),
    lint: () => lint(root, "ignore"),
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
  const [entry] = JSON.parse(readFileSync(join(swift.root, baselineFile), "utf8"))
  assert.equal(entry.violation.location.file, "packages/Example.swift")
  assert.equal(swift.lint(), 0)
  swift.write(swiftFunction("long", 61))
  assert.notEqual(swift.lint(), 0)
  swift.write(swiftFunction("long", 60), swiftFunction("added", 51))
  assert.notEqual(swift.lint(), 0)
})

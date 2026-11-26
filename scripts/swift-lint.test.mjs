import assert from "node:assert/strict"
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

import { baselineFile, lint, writeBaseline } from "./swift-lint.mjs"

const repoRoot = fileURLToPath(new URL("..", import.meta.url))
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

test("functions over 50 lines fail SwiftLint", (t) => {
  const swift = swiftPackage(t)
  swift.write(swiftFunction("short", 50))
  assert.equal(swift.lint(), 0)
  swift.write(swiftFunction("long", 51))
  assert.notEqual(swift.lint(), 0)
})

test("the baseline keeps old long functions but fails grown or new ones", (t) => {
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

const timerWithLeeway = (leeway, constant = "") =>
  [
    "  static func arm(_ timer: any DispatchSourceTimer) {",
    ...(constant === "" ? [] : [`    ${constant}`]),
    `    timer.schedule(deadline: .now(), leeway: ${leeway})`,
    "  }"
  ].join("\n")

const acceptedLeeways = [
  timerWithLeeway(".nanoseconds(0)"),
  timerWithLeeway("leeway", "let leeway: DispatchTimeInterval = .milliseconds(1)"),
  "  static func arm(_ timer: any DispatchSourceTimer) {\n    timer.schedule(deadline: .now(), repeating: .never)\n  }"
]

const rejectedLeeways = [
  timerWithLeeway(".never"),
  timerWithLeeway("DispatchTimeInterval.never"),
  timerWithLeeway("Dispatch.DispatchTimeInterval.never"),
  timerWithLeeway("leeway", "let leeway: DispatchTimeInterval = .never"),
  timerWithLeeway("leeway", "let leeway = DispatchTimeInterval.never"),
  timerWithLeeway("leeway", "let leeway: Dispatch.DispatchTimeInterval = .never")
]

test("a dispatch timer leeway of never fails SwiftLint in every spelling", (t) => {
  const swift = swiftPackage(t)
  for (const accepted of acceptedLeeways) {
    swift.write(accepted)
    assert.equal(swift.lint(), 0, accepted)
  }
  for (const rejected of rejectedLeeways) {
    swift.write(rejected)
    assert.notEqual(swift.lint(), 0, rejected)
  }
})

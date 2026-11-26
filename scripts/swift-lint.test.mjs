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

const armTimer = (...lines) =>
  [
    "  static func arm(_ timer: any DispatchSourceTimer) {",
    ...lines.map((line) => `    ${line}`),
    "  }"
  ].join("\n")

const scheduled = (leeway) => `timer.schedule(deadline: .now(), leeway: ${leeway})`

const acceptedTimers = [
  armTimer(scheduled(".nanoseconds(0)")),
  armTimer("let leeway: DispatchTimeInterval = .milliseconds(1)", scheduled("leeway")),
  armTimer("timer.schedule(deadline: .now(), repeating: .never)"),
  armTimer(
    "timer.schedule(deadline: .now(), repeating: DispatchTimeInterval.never, leeway: .nanoseconds(0))"
  ),
  armTimer("if interval == DispatchTimeInterval.never { return }", scheduled(".nanoseconds(0)"))
]

const rejectedTimers = [
  armTimer(scheduled(".never")),
  armTimer(scheduled("DispatchTimeInterval.never")),
  armTimer(scheduled("Dispatch.DispatchTimeInterval.never")),
  armTimer(scheduled("(.never)")),
  armTimer(scheduled("isStrict ? .nanoseconds(0) : .never")),
  armTimer("let leeway: DispatchTimeInterval = .never", scheduled("leeway")),
  armTimer("let leeway = DispatchTimeInterval.never", scheduled("leeway")),
  armTimer("let leeway: Dispatch.DispatchTimeInterval = .never", scheduled("leeway")),
  armTimer("let leeway: DispatchTimeInterval? = .never", scheduled("leeway ?? .nanoseconds(0)")),
  armTimer(
    "let leeway: DispatchTimeInterval = isStrict ? .nanoseconds(0) : .never",
    scheduled("leeway")
  )
]

test("a dispatch timer leeway of never fails SwiftLint in every spelling", (t) => {
  const swift = swiftPackage(t)
  for (const accepted of acceptedTimers) {
    swift.write(accepted)
    assert.equal(swift.lint(), 0, accepted)
  }
  for (const rejected of rejectedTimers) {
    swift.write(rejected)
    assert.notEqual(swift.lint(), 0, rejected)
  }
})

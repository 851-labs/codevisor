import assert from "node:assert/strict"
import { readFileSync, readdirSync } from "node:fs"
import { basename, join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

import { mainSerialExecutorFilter, mainSerialExecutorSuites, runSwiftTests } from "./test-swift.mjs"

const root = fileURLToPath(new URL("../packages/swift", import.meta.url))

function testSources(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    if (entry.name.startsWith(".") || entry.name === "Vendor") return []
    const path = join(directory, entry.name)
    if (entry.isDirectory()) return testSources(path)
    return path.includes("/Tests/") && path.endsWith(".swift") ? [path] : []
  })
}

test("every Swift suite that changes the global executor is isolated", () => {
  const suites = testSources(root)
    .filter((path) =>
      /\b(?:TestStore|TestStoreOf|withMainSerialExecutor)\b/.test(readFileSync(path, "utf8"))
    )
    .map((path) => basename(path, ".swift"))
  assert.deepEqual(suites.sort(), [...mainSerialExecutorSuites].sort())
})

test("test selections are complementary and unrelated suites cannot enter the isolated process", () => {
  const calls = []
  assert.equal(
    runSwiftTests(["--build-system", "native"], (executable, args) => {
      assert.equal(executable, "swift")
      calls.push(args)
      return { status: 0 }
    }),
    0
  )
  assert.equal(calls.length, 3)
  assert.equal(calls[0][calls[0].indexOf("--skip") + 1], mainSerialExecutorFilter)
  assert.equal(calls[1][calls[1].indexOf("--filter") + 1], mainSerialExecutorFilter)
  assert.ok(calls[1].includes("--skip-build"))
  assert.ok(!calls[2].includes("--skip") && !calls[2].includes("--filter"))
  const isolated = new RegExp(mainSerialExecutorFilter)
  for (const suite of mainSerialExecutorSuites) {
    assert.ok(isolated.test(`CodevisorCoreMacTests.${suite}/example()`))
  }
  assert.ok(!isolated.test("CodevisorCloudTests.CloudMachineKeyLookupTests/repeatedLookups()"))
  assert.ok(!isolated.test("CodevisorCoreTests.SessionModelTests/firstPrompt()"))
  for (const arg of ["--filter", "--filter=OtherTests", "--skip", "--package-path", "-s"]) {
    assert.throws(
      () => runSwiftTests([arg], () => assert.fail("must not launch Swift")),
      /cannot forward/
    )
  }
})

test("a failure in either test group stops the command and preserves its exit status", () => {
  for (const failedCall of [1, 2, 3]) {
    let calls = 0
    const status = runSwiftTests([], () => ({ status: ++calls === failedCall ? 17 : 0 }))
    assert.equal(status, 17)
    assert.equal(calls, failedCall)
  }
  assert.equal(
    runSwiftTests([], () => ({ status: null, signal: "SIGTERM" })),
    1
  )
})

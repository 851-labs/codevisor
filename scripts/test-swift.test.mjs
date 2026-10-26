import assert from "node:assert/strict"
import { readFileSync, readdirSync } from "node:fs"
import { basename, join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

import { mainSerialExecutorFilter, mainSerialExecutorSuites, runSwiftTests } from "./test-swift.mjs"

const testRoots = ["../packages/swift", "../apps/macos/Tests/Transcript"].map((path) =>
  fileURLToPath(new URL(path, import.meta.url))
)

function testSources(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    if (entry.name.startsWith(".") || entry.name === "Vendor") return []
    const path = join(directory, entry.name)
    if (entry.isDirectory()) return testSources(path)
    return path.includes("/Tests/") && path.endsWith(".swift") ? [path] : []
  })
}

test("every Swift suite that changes the global executor is isolated", () => {
  const suites = testRoots
    .flatMap(testSources)
    .filter((path) =>
      /\b(?:TestStore|TestStoreOf|withMainSerialExecutor)\b/.test(readFileSync(path, "utf8"))
    )
    .map((path) => basename(path, ".swift"))
  assert.deepEqual(
    suites.toSorted((a, b) => a.localeCompare(b)),
    [...mainSerialExecutorSuites].toSorted((a, b) => a.localeCompare(b))
  )
})

test("Swift tests use Swift Testing, because swift:test runs them without XCTest", () => {
  const xcTests = testRoots
    .flatMap(testSources)
    .filter((path) => /^\s*(?:@testable\s+)?import\s+XCTest\b/m.test(readFileSync(path, "utf8")))
  assert.deepEqual(xcTests, [])
})

const recorder = (failAt = 0, status = 17) => {
  const calls = []
  const step = () => (calls.length === failAt ? status : 0)
  return {
    calls,
    run: (executable, args) => {
      assert.equal(executable, "swift")
      calls.push(args)
      return { status: step() }
    },
    runBundles: async (packagePath, selection) => {
      calls.push(["bundles", packagePath, ...selection])
      return step()
    }
  }
}

test("test selections are complementary and unrelated suites cannot enter the isolated process", async () => {
  const { calls, run, runBundles } = recorder()
  assert.equal(await runSwiftTests(["--build-system", "native"], { run, runBundles }), 0)
  const [build, bundles, isolated] = calls
  assert.equal(calls.length, 3)
  assert.deepEqual(build.slice(0, 2), ["build", "--build-tests"])
  assert.ok(build.includes("--build-system"))
  assert.equal(bundles[bundles.indexOf("--skip") + 1], mainSerialExecutorFilter)
  assert.equal(isolated[isolated.indexOf("--filter") + 1], mainSerialExecutorFilter)
  assert.ok(isolated.includes("--skip-build"))
  const pattern = new RegExp(mainSerialExecutorFilter)
  for (const suite of mainSerialExecutorSuites) {
    assert.ok(pattern.test(`CodevisorCoreMacTests.${suite}/example()`))
  }
  assert.ok(!pattern.test("CodevisorCloudTests.CloudMachineKeyLookupTests/repeatedLookups()"))
  assert.ok(!pattern.test("CodevisorCoreTests.SessionModelTests/firstPrompt()"))
  for (const arg of ["--filter", "--filter=OtherTests", "--skip", "--package-path", "-s"]) {
    await assert.rejects(runSwiftTests([arg], recorder(1)), /cannot forward/)
  }
})

test("a failure in any step stops the command and preserves its exit status", async () => {
  for (const failAt of [1, 2, 3]) {
    const { calls, run, runBundles } = recorder(failAt)
    assert.equal(await runSwiftTests([], { run, runBundles }), 17)
    assert.equal(calls.length, failAt)
  }
  const killed = { run: () => ({ status: null, signal: "SIGTERM" }), runBundles: async () => 0 }
  assert.equal(await runSwiftTests([], killed), 1)
})

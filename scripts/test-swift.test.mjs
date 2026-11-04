import assert from "node:assert/strict"
import { chmodSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { basename, join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

import {
  hardwareCodecFilter,
  hardwareCodecSuites,
  mainSerialExecutorFilter,
  mainSerialExecutorSuites,
  runBundle,
  runSwiftTests,
  skipHardwareCodecTests
} from "./test-swift.mjs"

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

test("every Swift suite that takes the hardware codec lock can be skipped", () => {
  const lockedSuites = testRoots
    .flatMap(testSources)
    .filter((path) => /@Suite\([^)]*\.hardwareCodecLock/.test(readFileSync(path, "utf8")))
    .map((path) => basename(path, ".swift"))
  assert.ok(lockedSuites.length > 0)
  for (const suite of lockedSuites) assert.ok(hardwareCodecSuites.includes(suite), suite)
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

test("skipping the hardware codec tests removes them from both test runs and nothing else", async () => {
  const { calls, run, runBundles } = recorder()
  assert.equal(await runSwiftTests([skipHardwareCodecTests, "--parallel"], { run, runBundles }), 0)
  const [build, bundles, isolated] = calls
  assert.ok(!build.includes(skipHardwareCodecTests) && !build.includes("--skip"))
  for (const selection of [bundles, isolated]) {
    assert.ok(!selection.includes(skipHardwareCodecTests))
    assert.ok(selection.includes("--parallel"))
    assert.equal(selection[selection.lastIndexOf("--skip") + 1], hardwareCodecFilter)
  }
  assert.equal(bundles[bundles.indexOf("--skip") + 1], mainSerialExecutorFilter)
  assert.equal(isolated[isolated.indexOf("--filter") + 1], mainSerialExecutorFilter)
  const pattern = new RegExp(hardwareCodecFilter)
  for (const id of [
    "ScreenSharingTests.HardwareCodecTests/ScreenSharingCodecRoundTripTests/hevcRoundTrips()",
    "ScreenSharingV2Tests.HardwareCodecTests/ScreenSharingV2EngineTests/streams()",
    "ScreenSharingWebRTCTests.ScreenSharingPeerLoopbackTests/negotiationConnects()"
  ]) {
    assert.ok(pattern.test(id), id)
  }
  assert.ok(!pattern.test("ScreenSharingTests.RFBTightTests/decodesTight()"))
  assert.ok(!pattern.test("ScreenSharingWebRTCTests.ScreenSharingCodecFactoryTests/adapters()"))

  const full = recorder()
  await runSwiftTests([], full)
  assert.ok(full.calls.every((call) => !call.includes(hardwareCodecFilter)))
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

test("a test bundle that runs past its time limit is stopped and reported", async (t) => {
  const directory = mkdtempSync(join(tmpdir(), "test-swift-"))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  const helper = join(directory, "stuck-helper")
  writeFileSync(helper, "#!/bin/sh\nexec sleep 60\n")
  chmodSync(helper, 0o755)

  const result = await runBundle(helper, "Stuck.xctest", [], process.env, 100)

  assert.equal(result.timedOut, true)
  assert.equal(result.signal, "SIGKILL")
})

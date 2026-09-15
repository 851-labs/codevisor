import assert from "node:assert/strict"
import childProcess from "node:child_process"
import { EventEmitter } from "node:events"
import { syncBuiltinESMExports } from "node:module"
import test from "node:test"

import { launchIOSDevelopmentApp, pickIOSSimulator } from "./dev-ios-target.mjs"

const listing = {
  devices: {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
      { name: "iPhone 17 Pro", udid: "17pro-26-5", state: "Shutdown" },
      { name: "iPhone 17", udid: "17-26-5", state: "Shutdown" }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
      { name: "iPhone 18 Pro", udid: "18pro-27-0", state: "Shutdown" },
      { name: "iPhone 17", udid: "17-27-0", state: "Shutdown" }
    ],
    "com.apple.CoreSimulator.SimRuntime.watchOS-27-0": [
      { name: "iPhone 17 Pro", udid: "not-ios", state: "Shutdown" }
    ]
  }
}

test("picks the device from an older runtime when the newest runtime lacks it", () => {
  // Exactly the case a bare `name=` destination fails on: xcodebuild pins
  // OS:latest, where no "iPhone 17 Pro" exists.
  const simulator = pickIOSSimulator(listing, "iPhone 17 Pro")
  assert.equal(simulator.udid, "17pro-26-5")
  assert.equal(simulator.runtime, "iOS 26.5")
})

test("prefers the newest runtime when several have the device", () => {
  assert.equal(pickIOSSimulator(listing, "iPhone 17").udid, "17-27-0")
})

test("prefers a booted device over a newer runtime", () => {
  const booted = structuredClone(listing)
  booted.devices["com.apple.CoreSimulator.SimRuntime.iOS-26-5"][1].state = "Booted"
  assert.equal(pickIOSSimulator(booted, "iPhone 17").udid, "17-26-5")
})

test("an unknown device name fails with the override hint", () => {
  assert.throws(() => pickIOSSimulator(listing, "iPhone 3G"), /CODEVISOR_IOS_SIMULATOR/)
})

for (const terminationExitCode of [0, 3]) {
  test(`iOS launch waits for termination to exit with code ${terminationExitCode}`, async (t) => {
    t.mock.timers.enable({ apis: ["setTimeout"] })
    t.mock.method(console, "log", () => {})
    const terminationStarted = Promise.withResolvers()
    const termination = Object.assign(new EventEmitter(), { exitCode: null, signalCode: null })
    const commands = []
    const spawn = t.mock.method(childProcess, "spawn", (command, args) => {
      assert.equal(command, "xcrun")
      assert.equal(args[0], "simctl")
      commands.push(args[1])
      if (args[1] === "terminate") {
        terminationStarted.resolve()
        return termination
      }
      return { exitCode: 0, signalCode: null }
    })
    syncBuiltinESMExports()
    t.after(() => {
      spawn.mock.restore()
      syncBuiltinESMExports()
    })

    const operation = launchIOSDevelopmentApp({
      repoRoot: "/test/repo",
      target: {
        simulator: { udid: "test-device", name: "Test iPhone" },
        bundleIdentifier: "test.codevisor",
        appBundle: "/test/Codevisor.app"
      },
      environment: {},
      worktreeName: "test",
      instanceName: "test-instance",
      developmentIconColor: { hex: "#123456" },
      remoteHost: "127.0.0.1",
      remotePort: 50000,
      remoteToken: "test-token",
      remoteName: "Test Remote",
      urlScheme: "codevisor-test"
    }).then(
      () => ({ error: undefined }),
      (error) => ({ error })
    )

    try {
      await terminationStarted.promise
      // Even a long elapsed interval cannot release a pending termination.
      const elapsed = new Promise((resolve) => setTimeout(resolve, 60_000))
      t.mock.timers.tick(60_000)
      await elapsed
      assert.deepEqual(commands, ["install", "terminate"])

      termination.exitCode = terminationExitCode
      termination.emit("exit", terminationExitCode, null)
      assert.equal((await operation).error, undefined)
      assert.deepEqual(commands, ["install", "terminate", "launch"])
    } finally {
      termination.emit("exit", terminationExitCode, null)
      await operation
    }
  })
}

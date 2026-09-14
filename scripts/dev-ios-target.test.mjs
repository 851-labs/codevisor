import assert from "node:assert/strict"
import childProcess from "node:child_process"
import { EventEmitter } from "node:events"
import { syncBuiltinESMExports } from "node:module"
import test from "node:test"

import { launchIOSDevelopmentApp } from "./dev-ios-target.mjs"

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

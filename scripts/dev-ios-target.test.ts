import assert from "node:assert/strict"
import { EventEmitter } from "node:events"
import test from "node:test"

import { launchIOSDevelopmentApp } from "./dev-ios-target.ts"
import type { RequireSimulator, SpawnProcess } from "./dev-ios-target.ts"
import type { WorktreeColor } from "./dev-shared.ts"
import type { SimulatorManifest } from "./ios-simulator-state.ts"

for (const terminationExitCode of [0, 3]) {
  test(`iOS launch waits for termination to exit with code ${terminationExitCode}`, async (t) => {
    t.mock.timers.enable({ apis: ["setTimeout"] })
    t.mock.method(console, "log", () => {})
    const terminationStarted = Promise.withResolvers<void>()
    const termination = Object.assign(new EventEmitter(), {
      exitCode: null as number | null,
      signalCode: null
    })
    const commands: string[] = []
    // Injected rather than patched onto node:child_process: builtin module
    // namespaces are readonly under Bun, so a spawn mock there silently no-ops
    // and the test shells out to the real xcrun.
    // Only the `xcrun simctl` shape this path uses is implemented, so the stub
    // stands in for spawn's full overload set through a cast.
    const spawnProcess = ((command: string, args: readonly string[]) => {
      assert.equal(command, "xcrun")
      assert.equal(args[0], "simctl")
      commands.push(args[1])
      if (args[1] === "terminate") {
        terminationStarted.resolve()
        return termination
      }
      return { exitCode: 0, signalCode: null }
    }) as unknown as SpawnProcess

    const operation = launchIOSDevelopmentApp({
      repoRoot: "/test/repo",
      // The launch path reads only the lease off the resolved manifest.
      requireSimulator: (async () => ({ lease: "test-lease" })) as unknown as RequireSimulator,
      spawnProcess,
      target: {
        // simctl is addressed by udid; the name and lease are the rest of the
        // manifest this path reads.
        simulator: {
          udid: "test-device",
          name: "Test iPhone",
          lease: "test-lease"
        } as unknown as SimulatorManifest,
        bundleIdentifier: "test.codevisor",
        appBundle: "/test/Codevisor.app"
      },
      environment: {},
      worktreeName: "test",
      instanceName: "test-instance",
      // The icon tint is the only field of the worktree color used here.
      developmentIconColor: { hex: "#123456" } as unknown as WorktreeColor,
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

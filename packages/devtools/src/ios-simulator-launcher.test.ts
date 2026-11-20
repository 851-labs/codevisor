import { appendFile, writeFile } from "node:fs/promises"

import { expect, it } from "vitest"

import { startIOSSimulator, stopIOSSimulator } from "./ios-simulator-launcher.ts"
import {
  parseSimulatorArguments,
  simulatorLogPath,
  simulatorManifestPath
} from "./ios-simulator-state.ts"
import {
  failingOwner,
  harness,
  manifestFor,
  runningSimulator,
  worktree
} from "./ios-simulator-test-support.ts"

it("starts a detached owner, echoes its log, and returns once the simulator is ready", async () => {
  const repoRoot = await worktree()
  const { dependencies, output, starts } = harness(repoRoot)
  const startOwner = (logPath: string) => {
    starts.push(logPath)
    void (async () => {
      await appendFile(logPath, "Starting simulator\nSimulator ready: device-1\n")
      await runningSimulator(repoRoot)
    })()
    return { exited: new Promise<number>(() => {}), release: () => {} }
  }

  const code = await startIOSSimulator(repoRoot, parseSimulatorArguments([]), {
    ...dependencies,
    startOwner
  })

  expect(code).toBe(0)
  expect(starts).toEqual([simulatorLogPath(repoRoot)])
  expect(output.join("")).toMatch(
    /^Starting simulator\nSimulator ready: device-1\nStart the apps with bun run dev:ios\. /
  )
})

it("reports the owner's log when it exits before the simulator is ready", async () => {
  const repoRoot = await worktree()
  const { dependencies, output } = harness(repoRoot)

  const code = await startIOSSimulator(repoRoot, parseSimulatorArguments([]), {
    ...dependencies,
    startOwner: failingOwner
  })

  expect(code).toBe(1)
  expect(output.join("")).toContain("No installed iOS runtime\n")
  expect(output.join("")).toContain(`Its owner's log is ${simulatorLogPath(repoRoot)}`)
})

it("prints the running simulator instead of starting a second one", async () => {
  const repoRoot = await worktree()
  await runningSimulator(repoRoot)
  const { dependencies, output, starts } = harness(repoRoot)

  expect(await startIOSSimulator(repoRoot, parseSimulatorArguments([]), dependencies)).toBe(0)
  expect(starts).toEqual([])
  expect(output.join("")).toContain("This worktree's simulator is already running.")
  expect(output.join("")).toContain("  Device: device-1\n")
  expect(output.join("")).toContain("  Xcode: project window open\n")
})

it("refuses to reuse a running simulator of another device", async () => {
  const repoRoot = await worktree()
  await runningSimulator(repoRoot)
  const { dependencies, output } = harness(repoRoot)
  const options = parseSimulatorArguments(["--device=iPhone 17"])

  expect(await startIOSSimulator(repoRoot, options, dependencies)).toBe(1)
  expect(output.join("")).toContain("already running as iPhone 17 Pro (iOS 27.0)")
})

it("stops the owner and confirms its device is gone", async () => {
  const repoRoot = await worktree()
  await runningSimulator(repoRoot)
  const { dependencies, output, signals } = harness(repoRoot)

  expect(await stopIOSSimulator(repoRoot, dependencies)).toBe(0)
  expect(signals).toEqual(["42 SIGTERM"])
  expect(output.join("")).toContain("Deleted this worktree's simulator")
})

it("fails a stop that leaves the device behind", async () => {
  const repoRoot = await worktree()
  await writeFile(simulatorManifestPath(repoRoot), JSON.stringify(manifestFor(repoRoot)))
  const { dependencies, output } = harness(repoRoot, { alive: false })

  expect(await stopIOSSimulator(repoRoot, dependencies)).toBe(1)
  expect(output.join("")).toContain("Simulator device-1 was not deleted")
})

it("says so when there is nothing to stop", async () => {
  const repoRoot = await worktree()
  const { dependencies, output } = harness(repoRoot, { alive: false, devices: [] })

  expect(await stopIOSSimulator(repoRoot, dependencies)).toBe(0)
  expect(output.join("")).toBe("No simulator is running for this worktree.\n")
})

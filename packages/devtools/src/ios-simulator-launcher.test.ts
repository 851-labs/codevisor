import { appendFile, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"

import { afterEach, expect, it } from "vitest"

import { startIOSSimulator, stopIOSSimulator } from "./ios-simulator-launcher.ts"
import {
  parseSimulatorArguments,
  simulatorClaimPath,
  simulatorLogPath,
  simulatorManifestPath,
  simulatorName
} from "./ios-simulator-state.ts"

const cleanups: Array<() => Promise<unknown>> = []
afterEach(async () => {
  await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()))
})

const owner = { pid: 42, startedAt: "first", state: "S" }

async function worktree() {
  const repoRoot = await mkdtemp(join(tmpdir(), "codevisor-simulator-launcher-"))
  cleanups.push(() => rm(repoRoot, { recursive: true, force: true }))
  await mkdir(dirname(simulatorManifestPath(repoRoot)), { recursive: true })
  return repoRoot
}

function manifestFor(repoRoot: string) {
  return {
    format: "codevisor-ios-simulator-v1",
    repoRoot,
    name: simulatorName(repoRoot),
    udid: "device-1",
    deviceName: "iPhone 17 Pro",
    deviceType: "phone",
    runtime: "iOS 27.0",
    runtimeIdentifier: "runtime.iOS-27-0",
    lease: "lease-1",
    owner,
    ready: true,
    xcode: "project window open"
  }
}

async function runningSimulator(repoRoot: string) {
  await writeFile(simulatorClaimPath(repoRoot), JSON.stringify({ pid: 42, startedAt: "first" }))
  await writeFile(simulatorManifestPath(repoRoot), JSON.stringify(manifestFor(repoRoot)))
}

function harness(repoRoot: string, options: { alive?: boolean; devices?: Array<string> } = {}) {
  let alive = options.alive ?? true
  const devices = options.devices ?? ["device-1"]
  const output: Array<string> = []
  const starts: Array<string> = []
  const signals: Array<string> = []
  return {
    output,
    starts,
    signals,
    dependencies: {
      identity: async (pid: number) => (alive && pid === owner.pid ? owner : undefined),
      simctl: async () =>
        JSON.stringify({
          devices: {
            runtime: devices.map((udid) => ({
              udid,
              name: simulatorName(repoRoot),
              state: "Booted"
            }))
          }
        }),
      write: (text: string) => {
        output.push(text)
      },
      signal: (pid: number, signal: string) => {
        signals.push(`${pid} ${signal}`)
        alive = false
        devices.splice(0)
      },
      startOwner: (logPath: string) => {
        starts.push(logPath)
        return { exited: new Promise<number>(() => {}), release: () => {} }
      },
      pollMilliseconds: 1
    }
  }
}

const failingOwner = (logPath: string) => ({
  exited: appendFile(logPath, "No installed iOS runtime\n").then(() => 1),
  release: () => {}
})

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
  expect(output.join("")).toBe("Starting simulator\nSimulator ready: device-1\n")
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

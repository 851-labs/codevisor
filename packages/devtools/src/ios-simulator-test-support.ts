import { appendFile, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"

import { onTestFinished } from "vitest"

import { simulatorClaimPath, simulatorManifestPath, simulatorName } from "./ios-simulator-state.ts"

export const owner = { pid: 42, startedAt: "first", state: "S" }

export async function worktree() {
  const repoRoot = await mkdtemp(join(tmpdir(), "codevisor-simulator-launcher-"))
  onTestFinished(() => rm(repoRoot, { recursive: true, force: true }))
  await mkdir(dirname(simulatorManifestPath(repoRoot)), { recursive: true })
  return repoRoot
}

export function failingOwner(logPath: string) {
  return {
    exited: appendFile(logPath, "No installed iOS runtime\n").then(() => 1),
    release: () => {}
  }
}

export function manifestFor(repoRoot: string) {
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

export async function runningSimulator(repoRoot: string) {
  await writeFile(simulatorClaimPath(repoRoot), JSON.stringify({ pid: 42, startedAt: "first" }))
  await writeFile(simulatorManifestPath(repoRoot), JSON.stringify(manifestFor(repoRoot)))
}

export function harness(
  repoRoot: string,
  options: { alive?: boolean; devices?: Array<string> } = {}
) {
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

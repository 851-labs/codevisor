import { appendFile, writeFile } from "node:fs/promises"

import { expect, it } from "vitest"

import { prepareDevelopmentSimulator } from "./dev-ios-simulator.ts"
import { simulatorManifestPath } from "./ios-simulator-state.ts"
import {
  failingOwner,
  harness,
  manifestFor,
  runningSimulator,
  worktree
} from "./ios-simulator-test-support.ts"

it("leaves the simulator alone for runners other than dev:ios", async () => {
  const repoRoot = await worktree()
  const { dependencies, output, starts } = harness(repoRoot)

  for (const runner of [[], ["--linux"], ["--reuse-macos-build"], ["--bogus"]])
    expect(await prepareDevelopmentSimulator(repoRoot, runner, dependencies)).toBe(true)
  expect(starts).toEqual([])
  expect(output).toEqual([])
})

it("starts the default simulator when dev:ios finds none", async () => {
  const repoRoot = await worktree()
  const { dependencies, output, starts } = harness(repoRoot)
  const startOwner = (logPath: string) => {
    starts.push(logPath)
    void (async () => {
      await appendFile(logPath, "Simulator ready: device-1\n")
      await runningSimulator(repoRoot)
    })()
    return { exited: new Promise<number>(() => {}), release: () => {} }
  }

  expect(
    await prepareDevelopmentSimulator(repoRoot, ["--ios"], { ...dependencies, startOwner })
  ).toBe(true)
  expect(starts).toHaveLength(1)
  expect(output.join("")).toContain("Simulator ready: device-1\nStarted this worktree's simulator.")
})

it("reuses the running simulator and says it stays up", async () => {
  const repoRoot = await worktree()
  await runningSimulator(repoRoot)
  const { dependencies, output, starts } = harness(repoRoot)

  expect(await prepareDevelopmentSimulator(repoRoot, ["--ios"], dependencies)).toBe(true)
  expect(starts).toEqual([])
  expect(output.join("")).toBe(
    "Reusing this worktree's simulator: iPhone 17 Pro, iOS 27.0 (device-1). It stays up when dev:ios stops, so later runs reuse it; remove it with bun run ios-simulator --stop.\n"
  )
})

it("reuses a simulator started with another device and explains why it is not the default", async () => {
  const repoRoot = await worktree()
  await runningSimulator(repoRoot)
  await writeFile(
    simulatorManifestPath(repoRoot),
    JSON.stringify({ ...manifestFor(repoRoot), deviceName: "iPhone 17" })
  )
  const { dependencies, output } = harness(repoRoot)

  expect(await prepareDevelopmentSimulator(repoRoot, ["--ios"], dependencies)).toBe(true)
  expect(output.join("")).toContain("Reusing this worktree's simulator: iPhone 17, iOS 27.0")
  expect(output.join("")).toContain("It is not the default iPhone 17 Pro")
})

it("stops dev:ios when the simulator cannot start", async () => {
  const repoRoot = await worktree()
  const { dependencies, output } = harness(repoRoot)

  expect(
    await prepareDevelopmentSimulator(repoRoot, ["--ios"], {
      ...dependencies,
      startOwner: failingOwner
    })
  ).toBe(false)
  expect(output.join("")).toContain("The simulator did not start.")
})

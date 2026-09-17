import assert from "node:assert/strict"
import test from "node:test"

import type { ProcessIdentity } from "../packages/processes/src/index.mjs"
import {
  deleteOwnedSimulator,
  parseSimulatorArguments,
  reapOrphanedSimulators,
  requireIOSSimulator,
  selectSimulatorConfiguration,
  simulatorName
} from "./ios-simulator-state.ts"
import type {
  SimulatorDependencies,
  SimulatorDevice,
  SimulatorDeviceType,
  SimulatorManifest,
  SimulatorRuntime
} from "./ios-simulator-state.ts"

// Ownership checks read the pid and the launch fields off a process identity;
// the fixture implements that subset of the process table entry.
const owner = { pid: 42, startedAt: "first", state: "S" } as unknown as ProcessIdentity
const manifest: SimulatorManifest = {
  format: "codevisor-ios-simulator-v1",
  owner,
  repoRoot: "/repo/a",
  udid: "owned",
  name: "Codevisor Worktree a",
  lease: "lease-a",
  ready: true
}
const device: SimulatorDevice = { udid: manifest.udid, name: manifest.name, state: "Booted" }
const listing = (devices: readonly SimulatorDevice[]) =>
  JSON.stringify({ devices: { runtime: devices } })

test("device/runtime options select a supported installed runtime", () => {
  assert.deepEqual(parseSimulatorArguments(["--device=iPhone 17", "--runtime", "27.0"]), {
    device: "iPhone 17",
    runtime: "27.0",
    help: false
  })
  assert.equal(parseSimulatorArguments(["--help"]).help, true)
  assert.throws(() => parseSimulatorArguments(["--device"]), /requires a value/)
  assert.throws(() => parseSimulatorArguments(["--port=50"]), /Unknown/)
  const types: SimulatorDeviceType[] = [{ name: "iPhone 17", identifier: "phone" }]
  const runtimes: SimulatorRuntime[] = [26, 27].map((version) => ({
    identifier: `runtime.iOS-${version}`,
    version: `${version}.0`,
    isAvailable: true,
    // simctl names each supported device type too; selection reads only the
    // identifier, so the fixtures implement that subset.
    supportedDeviceTypes: [{ identifier: "phone" }] as unknown as SimulatorDeviceType[]
  }))
  assert.equal(
    selectSimulatorConfiguration({ device: "phone" }, types, runtimes).runtime,
    "iOS 27.0"
  )
  assert.equal(
    selectSimulatorConfiguration({ device: "iPhone 17", runtime: "26.0" }, types, runtimes).runtime,
    "iOS 26.0"
  )
  assert.throws(
    () => selectSimulatorConfiguration({ device: "missing" }, types, runtimes),
    /Unknown simulator device/
  )
  assert.throws(
    () => selectSimulatorConfiguration({ device: "phone", runtime: "25" }, types, runtimes),
    /No installed iOS runtime/
  )
  assert.notEqual(simulatorName("/repo/a"), simulatorName("/another/a"))
})

test("selects an older compatible iOS runtime when the latest cannot run the device", () => {
  const runtime = (platform: string, version: string, deviceType: string): SimulatorRuntime => ({
    identifier: `com.apple.CoreSimulator.SimRuntime.${platform}-${version.replaceAll(".", "-")}`,
    version,
    isAvailable: true,
    supportedDeviceTypes: [{ identifier: deviceType }] as unknown as SimulatorDeviceType[]
  })
  const result = selectSimulatorConfiguration(
    { device: "iPhone 17 Pro" },
    [{ name: "iPhone 17 Pro", identifier: "phone" }],
    [
      runtime("iOS", "26.4", "phone"),
      runtime("iOS", "26.5", "phone"),
      runtime("iOS", "27.0", "new-phone"),
      runtime("watchOS", "27.0", "phone")
    ]
  )
  assert.equal(result.runtime, "iOS 26.5")
  assert.equal(result.deviceType, "phone")
})

test("dev startup requires the live owner and the exact booted device", async () => {
  const deps: SimulatorDependencies = {
    read: async () => manifest,
    identity: async () => owner,
    simctl: async () => listing([device])
  }
  assert.deepEqual(await requireIOSSimulator("/repo/a", deps), manifest)
  for (const override of [
    { read: async () => undefined },
    { read: async () => ({ ...manifest, ready: false }) },
    { identity: async () => ({ ...owner, startedAt: "reused" }) },
    { simctl: async () => listing([{ ...device, state: "Shutdown" }]) },
    { simctl: async () => listing([{ ...device, udid: "other" }]) }
  ])
    await assert.rejects(
      requireIOSSimulator("/repo/a", { ...deps, ...override }),
      /bun run ios-simulator/
    )
  await assert.rejects(requireIOSSimulator("/repo/b", deps), /bun run ios-simulator/)
})

test("cleanup verifies ownership, targets only its UUID, and preserves a newer lease", async () => {
  const calls: (readonly string[])[] = []
  let removed = false
  const deps: SimulatorDependencies = {
    read: async (path) => (path === "marker" ? manifest : { ...manifest, lease: "replacement" }),
    ownerPath: () => "marker",
    remove: async () => {
      removed = true
    },
    simctl: async (args) => {
      calls.push(args)
      return listing([device, { ...device, udid: "another" }])
    }
  }
  await deleteOwnedSimulator(manifest, deps)
  assert.deepEqual(calls, [
    ["list", "devices", "--json"],
    ["shutdown", "owned"],
    ["delete", "owned"]
  ])
  assert.equal(removed, false)
  calls.length = 0
  await deleteOwnedSimulator({ ...manifest, lease: "wrong" }, deps)
  assert.deepEqual(calls, [])
  await deleteOwnedSimulator(manifest, { ...deps, read: async () => manifest })
  assert.equal(removed, true)
})

test("orphan recovery skips live owners and unmarked user devices", async () => {
  const calls: (readonly string[])[] = []
  const deps: SimulatorDependencies = {
    read: async (path) => (path === "owned" ? manifest : undefined),
    ownerPath: (id) => id,
    remove: async () => {},
    identity: async () => owner,
    simctl: async (args) => {
      calls.push(args)
      return listing([
        device,
        { ...device, udid: "unmarked" },
        { ...device, udid: "user", name: "My iPhone" }
      ])
    }
  }
  await reapOrphanedSimulators(deps)
  assert.deepEqual(calls, [["list", "devices", "--json"]])
  calls.length = 0
  await reapOrphanedSimulators({ ...deps, identity: async () => undefined })
  assert.deepEqual(
    calls.filter(([command]) => command === "delete"),
    [["delete", "owned"]]
  )
})

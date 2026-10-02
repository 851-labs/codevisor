import { randomUUID } from "node:crypto"

import type { ScreenSharingRequest } from "@codevisor/api"
import { describe, expect, it, vi } from "vitest"

import { parseDisplays, parseSimulatorList } from "./simulator-parsing.js"
import { makeSimulators, type SimulatorEnvironment, type Simulators } from "./simulators.js"
import { jsonRequest, makeServices, run, runningServers, startWithApp } from "./test-support.js"

const udid = "8C2D33A1-7E5B-4F0A-9C3D-2B1E4F6A7D90"
const list = {
  devicetypes: [
    {
      identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Air",
      name: "iPhone Air",
      productFamily: "iPhone",
      bundlePath: "/types/iPhone Air.simdevicetype"
    },
    {
      identifier: "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K",
      name: "Apple TV 4K",
      productFamily: "Apple TV"
    }
  ],
  runtimes: [
    {
      identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
      name: "iOS 27.0",
      platform: "iOS",
      version: "27.0",
      isAvailable: true,
      supportedDeviceTypes: [{ identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Air" }]
    },
    { identifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-0", isAvailable: false }
  ],
  devices: {
    "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
      {
        udid: udid.toLowerCase(),
        name: "Air",
        state: "Booted",
        isAvailable: true,
        deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Air"
      },
      { udid: "not-a-udid", name: "Broken", isAvailable: true }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
      { udid: randomUUID(), name: "Orphan", isAvailable: true }
    ]
  }
}

/// A Mac whose `xcrun simctl` answers from `list`, recording every command.
const fakeMac = (overrides: Partial<SimulatorEnvironment> = {}) => {
  const commands: string[][] = []
  let now = 0
  const environment: SimulatorEnvironment = {
    platform: "darwin",
    run: async (file, args) => {
      commands.push([file, ...args])
      if (args[0] === "simctl" && args[1] === "list")
        return { stdout: Buffer.from(JSON.stringify(list)) }
      if (args[0] === "simctl" && args[1] === "ui" && args.length === 4)
        return { stdout: Buffer.from(args[3] === "appearance" ? "dark\n" : "unsupported\n") }
      return { stdout: Buffer.alloc(0) }
    },
    readFile: async () => Buffer.alloc(0),
    listDirectory: async () => [],
    isFile: async () => false,
    withTemporaryDirectory: (body) => body("/tmp/simulator-test"),
    now: () => now,
    ...overrides
  }
  return { environment, commands, advance: (ms: number) => (now += ms) }
}

describe("simulator list", () => {
  it("keeps available devices on available runtimes, with their type and runtime", () => {
    const parsed = parseSimulatorList(list)
    expect(parsed.devices).toEqual([
      {
        udid,
        name: "Air",
        state: "Booted",
        runtime: {
          identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
          name: "iOS 27.0",
          platform: "iOS",
          version: "27.0"
        },
        deviceType: {
          identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Air",
          name: "iPhone Air",
          productFamily: "iPhone"
        }
      }
    ])
    expect(parsed.runtimes.map((runtime) => runtime.identifier)).toEqual([
      "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
    ])
  })

  it("takes a device type's own screens, not its external outputs", () => {
    const masks = new Map([["MASK", "cGRm"]])
    const displays = parseDisplays(
      [
        {
          deviceName: "primary",
          displayType: "integrated",
          width: 1260,
          height: 2736,
          scale: 3,
          cornerRadiusUL: 62,
          framebufferMaskIdentifier: "MASK",
          chromeIdentifier: "com.apple.dt.devicekit.chrome.phone12",
          hasDigitizer: true
        },
        { deviceName: "external-0", displayType: "tvOut", powerState: 0, width: 720, height: 480 }
      ],
      masks
    )
    expect(displays).toEqual([
      {
        name: "primary",
        width: 1260,
        height: 2736,
        scale: 3,
        cornerRadii: [62, 0, 0, 0],
        chromeIdentifier: "com.apple.dt.devicekit.chrome.phone12",
        mask: "cGRm",
        hasDigitizer: true
      }
    ])
    // An Apple TV has no integrated screen; its powered TV output is the screen.
    expect(
      parseDisplays(
        [
          {
            deviceName: "external-0",
            displayType: "tvOut",
            powerState: 1,
            width: 3840,
            height: 2160
          }
        ],
        masks
      ).map((display) => display.name)
    ).toEqual(["external-0"])
  })
})

describe("simulator availability", () => {
  it("needs macOS, the native app and Xcode runtimes", async () => {
    expect(await makeSimulators(fakeMac({ platform: "linux" }).environment).available()).toBe(false)
    expect(await makeSimulators(fakeMac().environment, () => false).available()).toBe(false)
    const noXcode = fakeMac({
      run: async () => {
        throw new Error('xcrun: error: unable to find utility "simctl"')
      }
    })
    expect(await makeSimulators(noXcode.environment).available()).toBe(false)
    expect(await makeSimulators(fakeMac().environment).available()).toBe(true)
  })

  it("caches the probe and retries a failed one after 30 seconds", async () => {
    let installed = false
    const mac = fakeMac()
    const probe = vi.fn(mac.environment.run)
    const simulators = makeSimulators({
      ...mac.environment,
      run: async (file, args, options) => {
        if (!installed) throw new Error("no Xcode")
        return probe(file, args, options)
      }
    })
    expect(await simulators.available()).toBe(false)
    installed = true
    mac.advance(29_999)
    expect(await simulators.available()).toBe(false)
    mac.advance(1)
    expect(await simulators.available()).toBe(true)
    expect(await simulators.available()).toBe(true)
    expect(probe).toHaveBeenCalledOnce()
  })
})

describe("simulator commands", () => {
  it("applies settings through simctl and reports what the device supports", async () => {
    const mac = fakeMac()
    const simulators = makeSimulators(mac.environment)
    const settings = await simulators.changeSettings({
      udid,
      appearance: "dark",
      increaseContrast: true,
      location: "city-run"
    })
    expect(mac.commands).toContainEqual(["xcrun", "simctl", "ui", udid, "appearance", "dark"])
    expect(mac.commands).toContainEqual([
      "xcrun",
      "simctl",
      "ui",
      udid,
      "increase_contrast",
      "enabled"
    ])
    expect(mac.commands).toContainEqual(["xcrun", "simctl", "location", udid, "run", "City Run"])
    // Unsupported settings are left out; the location is what this server last set.
    expect(settings).toEqual({ appearance: "dark", location: "city-run" })
  })

  it("reads screenshots back from the file simctl writes", async () => {
    const image = Buffer.from("png bytes")
    const mac = fakeMac({
      readFile: async (path) =>
        path === "/tmp/simulator-test/screenshot.png" ? image : Buffer.alloc(0)
    })
    expect(await makeSimulators(mac.environment).screenshot(udid)).toEqual(image)
    expect(mac.commands).toContainEqual([
      "xcrun",
      "simctl",
      "io",
      udid,
      "screenshot",
      "--type=png",
      "/tmp/simulator-test/screenshot.png"
    ])
  })

  it("only boots a device that isn't running, and rejects unknown ones", async () => {
    const mac = fakeMac()
    const simulators = makeSimulators(mac.environment)
    await simulators.perform(udid, "boot")
    expect(mac.commands.some((command) => command[2] === "boot")).toBe(false)
    await simulators.perform(udid, "shutdown")
    expect(mac.commands).toContainEqual(["xcrun", "simctl", "shutdown", udid])
    await expect(simulators.perform(randomUUID(), "boot")).rejects.toMatchObject({ status: 404 })
    await expect(simulators.perform("../etc", "boot")).rejects.toMatchObject({ status: 400 })
  })
})

const stubSimulators = (available: boolean): Simulators => ({
  ...makeSimulators(fakeMac().environment),
  available: async () => available
})

describe("simulator routes", () => {
  it("advertises simulator-v1 only when simulators can stream here", async () => {
    for (const [config, expected] of [
      [{ simulators: stubSimulators(true), screenSharing: async () => ({}) }, true],
      [{ simulators: stubSimulators(false), screenSharing: async () => ({}) }, false],
      [{ simulators: stubSimulators(true) }, false],
      [{}, false]
    ] as const) {
      const { services } = await makeServices()
      const server = await startWithApp(services, undefined, config)
      runningServers.push(server)
      const info = await jsonRequest(server, "/v1/info")
      expect((info.body as { features: string[] }).features.includes("simulator-v1")).toBe(expected)
      const devices = await jsonRequest(server, "/v1/simulators")
      expect(devices.status).toBe(expected ? 200 : 501)
    }
  })

  it("streams a simulator only to a Simulator pane", async () => {
    const helper = vi.fn(async () => ({ version: 1, status: "connecting", displays: [] }))
    const { services } = await makeServices()
    const server = await startWithApp(services, undefined, { screenSharing: helper })
    runningServers.push(server)
    const project = await run(services.db.createProject({ folderPath: "/fixture/simulator" }))
    const workspace = await run(
      services.db.upsertWorkspace({ projectId: project.id, name: "Sim", hasCustomName: false })
    )
    const paneOf = async (paneType: string) =>
      run(
        services.db.upsertWorkspacePane(workspace.id, {
          id: randomUUID(),
          providerId: "codevisor",
          paneType,
          title: paneType
        })
      )
    const start = (paneId: string, displayId = `simulator:${udid}`): ScreenSharingRequest => ({
      version: 1,
      operation: "start",
      workspaceId: workspace.id,
      paneId,
      viewerId: randomUUID(),
      displayId,
      offer: "v=0\r\na=fingerprint:sha-256 fixture\r\n"
    })
    const post = (body: ScreenSharingRequest) =>
      jsonRequest(server, "/v1/screen-sharing", { method: "POST", body: JSON.stringify(body) })
    const simulatorPane = await paneOf("simulator")
    const sharingPane = await paneOf("screen-sharing")
    expect((await post(start(simulatorPane.id))).status).toBe(200)
    expect((await post(start(sharingPane.id))).status).toBe(404)
    expect((await post(start(simulatorPane.id, "simulator:../../etc"))).status).toBe(400)
    expect(helper).toHaveBeenCalledOnce()
  })
})

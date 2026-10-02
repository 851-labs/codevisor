import { writeFile } from "node:fs/promises"
import { basename, dirname, join } from "node:path"

import { describe, expect, it } from "vitest"

import {
  makeSimulators,
  SimulatorCommandError,
  systemSimulatorEnvironment,
  type SimulatorEnvironment
} from "./simulators.js"

const udid = "8C2D33A1-7E5B-4F0A-9C3D-2B1E4F6A7D90"
const runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
const phone = "/types/iPhone 17.simdevicetype/Contents/Resources"
const pad = "/types/iPad.simdevicetype/Contents/Resources"
const tv = "/types/Apple TV.simdevicetype/Contents/Resources"

const list = (state: string) => ({
  devicetypes: [
    { identifier: "phone", name: "iPhone 17", bundlePath: dirname(dirname(phone)) },
    { identifier: "pad", name: "iPad", productFamily: "iPad", bundlePath: dirname(dirname(pad)) },
    {
      identifier: "tv",
      name: "Apple TV",
      productFamily: "Apple TV",
      bundlePath: dirname(dirname(tv))
    },
    { identifier: "watch", name: "Watch" }
  ],
  runtimes: [{ identifier: runtime, name: "iOS 27.0", version: "27.0" }],
  devices: { [runtime]: [{ udid, name: "Phone", state, deviceTypeIdentifier: "phone" }] }
})

interface FakeMac {
  readonly state?: string
  readonly files?: Readonly<Record<string, string>>
  readonly plists?: Readonly<Record<string, unknown>>
  readonly ui?: Readonly<Record<string, string>>
  readonly created?: string
}

/// A Mac with one simulator, some DeviceKit files and device-type plists, recording each command.
const fakeMac = (mac: FakeMac = {}) => {
  const commands: string[][] = []
  const reads: string[] = []
  const files = new Map(Object.entries(mac.files ?? {}))
  const environment: SimulatorEnvironment = {
    platform: "darwin",
    run: async (file, args) => {
      commands.push([file, ...args])
      if (file === "plutil") {
        const plist = mac.plists?.[args.at(-1) ?? ""]
        if (plist === undefined) throw new SimulatorCommandError("No such file")
        return { stdout: Buffer.from(JSON.stringify(plist)) }
      }
      if (args[1] === "list")
        return { stdout: Buffer.from(JSON.stringify(list(mac.state ?? "Booted"))) }
      if (args[1] === "ui" && args.length === 4) {
        const value = mac.ui?.[args[3] ?? ""]
        if (value === undefined) throw new SimulatorCommandError("Unsupported")
        return { stdout: Buffer.from(`${value}\n`) }
      }
      if (args[1] === "create")
        return { stdout: Buffer.from(`${mac.created ?? udid.toLowerCase()}\n`) }
      return { stdout: Buffer.alloc(0) }
    },
    readFile: async (path) => {
      reads.push(path)
      const contents = files.get(path)
      if (contents === undefined) throw new Error(`ENOENT: ${path}`)
      return Buffer.from(contents)
    },
    listDirectory: async (path) =>
      [...files.keys()].filter((file) => dirname(file) === path).map((file) => basename(file)),
    isFile: async (path) => files.has(path),
    withTemporaryDirectory: (body) => body("/tmp/simulator-test"),
    now: () => 0
  }
  const simctl = () =>
    commands
      .filter((command) => command[1] === "simctl" && command[2] !== "list")
      .map((command) => command.slice(2))
  return { environment, commands, reads, simctl }
}

const base64 = (text: string) => Buffer.from(text).toString("base64")

describe("simulator device types", () => {
  it("describes a type from its profile and screens, with each screen's mask", async () => {
    const mac = fakeMac({
      plists: {
        [`${phone}/profile.plist`]: {
          chromeIdentifier: "com.apple.dt.devicekit.chrome.phone12",
          supportedFeatures: { "com.apple.feature.posture": true }
        },
        [`${phone}/capabilities.plist`]: {
          capabilities: {
            displays: [
              {
                deviceName: "primary",
                displayType: "integrated",
                width: 1206,
                height: 2622,
                scale: 3,
                framebufferMaskIdentifier: "Phone17"
              },
              {
                displayType: "integrated",
                width: 10,
                height: 10,
                framebufferMaskIdentifier: "Bundled"
              },
              {
                displayType: "integrated",
                width: 1,
                height: 1,
                framebufferMaskIdentifier: "../escape"
              },
              {
                displayType: "integrated",
                width: 2,
                height: 2,
                framebufferMaskIdentifier: "Missing"
              },
              { displayType: "integrated", width: 3, height: 3 }
            ]
          }
        }
      },
      files: {
        "/Library/Developer/DeviceKit/FramebufferMasks/Phone17.pdf": "shared mask",
        [`${phone}/Bundled.pdf`]: "bundled mask"
      }
    })
    const simulators = makeSimulators(mac.environment)
    const detail = await simulators.deviceType("phone")
    expect(detail).toMatchObject({
      identifier: "phone",
      name: "iPhone 17",
      productFamily: "iPhone",
      features: ["com.apple.feature.posture"],
      chromeIdentifier: "com.apple.dt.devicekit.chrome.phone12"
    })
    expect(detail.displays.map((display) => display.mask)).toEqual([
      base64("shared mask"),
      base64("bundled mask"),
      undefined,
      undefined,
      undefined
    ])
    // Asked again, it comes from memory.
    const commands = mac.commands.length
    expect(await simulators.deviceType("phone")).toBe(detail)
    expect(mac.commands.length).toBe(commands)
  })

  it("does without a capabilities plist or its screens", async () => {
    const mac = fakeMac({
      plists: {
        [`${tv}/profile.plist`]: {},
        [`${pad}/profile.plist`]: {},
        [`${pad}/capabilities.plist`]: {}
      }
    })
    const simulators = makeSimulators(mac.environment)
    expect(await simulators.deviceType("tv")).toEqual({
      identifier: "tv",
      name: "Apple TV",
      productFamily: "Apple TV",
      features: [],
      displays: []
    })
    expect((await simulators.deviceType("pad")).displays).toEqual([])
  })

  it("refuses a type that isn't installed", async () => {
    const simulators = makeSimulators(fakeMac().environment)
    await expect(simulators.deviceType("watch")).rejects.toMatchObject({ status: 404 })
    await expect(simulators.deviceType("toaster")).rejects.toMatchObject({ status: 404 })
  })
})

describe("simulator chrome", () => {
  const resources = "/Library/Developer/DeviceKit/Chrome/phone12.devicechrome/Contents/Resources"

  it("loads a chrome's definition and the images it has", async () => {
    const definition = { images: { frame: "PhoneFrame" }, inputs: [{ image: "VolumeUp" }] }
    const mac = fakeMac({
      files: {
        [`${resources}/chrome.json`]: JSON.stringify(definition),
        [`${resources}/PhoneFrame.pdf`]: "frame"
      }
    })
    const simulators = makeSimulators(mac.environment)
    const identifier = "com.apple.dt.devicekit.chrome.phone12"
    const chrome = await simulators.chrome(identifier)
    expect(chrome).toEqual({ identifier, definition, images: { PhoneFrame: base64("frame") } })
    const reads = mac.reads.length
    expect(await simulators.chrome(identifier)).toBe(chrome)
    expect(mac.reads.length).toBe(reads)
  })

  it("refuses a path or a chrome that isn't installed", async () => {
    const simulators = makeSimulators(fakeMac().environment)
    await expect(simulators.chrome("com.apple.dt.devicekit.chrome.../x")).rejects.toMatchObject({
      status: 400
    })
    await expect(simulators.chrome("com.apple.dt.devicekit.chrome.tablet")).rejects.toMatchObject({
      status: 404
    })
  })
})

describe("simulator settings", () => {
  it("reads what simctl reports and leaves out what it can't", async () => {
    const known = fakeMac({
      ui: { appearance: "light", content_size: "extra-large", increase_contrast: "disabled" }
    })
    expect(await makeSimulators(known.environment).settings(udid)).toEqual({
      appearance: "light",
      contentSize: "extra-large",
      increaseContrast: false,
      location: "none"
    })
    const odd = fakeMac({
      ui: { appearance: "unknown", content_size: "gigantic", increase_contrast: "" }
    })
    expect(await makeSimulators(odd.environment).settings(udid)).toEqual({ location: "none" })
    expect(await makeSimulators(fakeMac().environment).settings(udid)).toEqual({ location: "none" })
  })

  it("sets text size, turns contrast off and clears the location", async () => {
    const mac = fakeMac()
    const settings = await makeSimulators(mac.environment).changeSettings({
      udid,
      contentSize: "large",
      increaseContrast: false,
      location: "none"
    })
    expect(mac.simctl()).toEqual([
      ["ui", udid, "content_size", "large"],
      ["ui", udid, "increase_contrast", "disabled"],
      ["location", udid, "clear"],
      ["ui", udid, "appearance"],
      ["ui", udid, "content_size"],
      ["ui", udid, "increase_contrast"]
    ])
    expect(settings).toEqual({ location: "none" })
  })
})

describe("simulator appearance", () => {
  it("changes only the setting asked for", async () => {
    const mac = fakeMac()
    await makeSimulators(mac.environment).changeSettings({ udid, appearance: "light" })
    expect(mac.simctl()[0]).toEqual(["ui", udid, "appearance", "light"])
    expect(mac.simctl().filter((command) => command.length > 3)).toHaveLength(1)
  })
})

describe("simulator lifecycle", () => {
  it("starts a stopped device and leaves it stopped when asked to stop", async () => {
    const mac = fakeMac({ state: "Shutdown" })
    const simulators = makeSimulators(mac.environment)
    await simulators.perform(udid, "shutdown")
    await simulators.perform(udid, "boot")
    await simulators.perform(udid, "restart")
    await simulators.perform(udid, "delete")
    expect(mac.simctl()).toEqual([
      ["boot", udid],
      ["boot", udid],
      ["delete", udid]
    ])
  })

  it("stops a running device before restarting or deleting it", async () => {
    const mac = fakeMac()
    const simulators = makeSimulators(mac.environment)
    await simulators.perform(udid, "restart")
    await simulators.perform(udid, "delete")
    expect(mac.simctl()).toEqual([
      ["shutdown", udid],
      ["boot", udid],
      ["shutdown", udid],
      ["delete", udid]
    ])
  })

  it("creates a device with a trimmed name and answers its id", async () => {
    const mac = fakeMac()
    const simulators = makeSimulators(mac.environment)
    expect(await simulators.create("  Test Phone  ", "phone", runtime)).toBe(udid)
    expect(mac.simctl()).toEqual([["create", "Test Phone", "phone", runtime]])
    await expect(simulators.create("   ", "phone", runtime)).rejects.toMatchObject({ status: 400 })
    await expect(simulators.create("x".repeat(121), "phone", runtime)).rejects.toMatchObject({
      status: 400
    })
    await expect(simulators.create("Phone", "phone type", runtime)).rejects.toMatchObject({
      status: 400
    })
    await expect(simulators.create("Phone", "phone", "a/b")).rejects.toMatchObject({ status: 400 })
    const garbled = makeSimulators(fakeMac({ created: "An error occurred" }).environment)
    await expect(garbled.create("Phone", "phone", runtime)).rejects.toBeInstanceOf(
      SimulatorCommandError
    )
  })

  it("renames a device it knows to a real name", async () => {
    const mac = fakeMac()
    const simulators = makeSimulators(mac.environment)
    await simulators.rename(udid.toLowerCase(), " Work Phone ")
    expect(mac.simctl()).toEqual([["rename", udid, "Work Phone"]])
    await expect(simulators.rename(udid, "")).rejects.toMatchObject({ status: 400 })
    await expect(simulators.rename(udid, "y".repeat(121))).rejects.toMatchObject({ status: 400 })
    await expect(
      simulators.rename("00000000-0000-4000-8000-000000000000", "Name")
    ).rejects.toMatchObject({ status: 404 })
  })

  it("probes availability once for callers that ask together", async () => {
    const mac = fakeMac()
    let lists = 0
    const simulators = makeSimulators({
      ...mac.environment,
      run: async (file, args, options) => {
        if (args[1] === "list") lists += 1
        return mac.environment.run(file, args, options)
      }
    })
    expect(await Promise.all([simulators.available(), simulators.available()])).toEqual([
      true,
      true
    ])
    expect(lists).toBe(1)
  })
})

describe("the system environment", () => {
  const options = { timeoutMs: 10_000, maxBytes: 64 * 1024 }

  it("runs a command, failing with its error output or exit", async () => {
    const result = await systemSimulatorEnvironment.run("/bin/sh", ["-c", "printf hello"], options)
    expect(result.stdout.toString("utf8")).toBe("hello")
    await expect(
      systemSimulatorEnvironment.run(
        "/bin/sh",
        ["-c", "echo 'no such device' >&2; exit 3"],
        options
      )
    ).rejects.toThrow("no such device")
    await expect(
      systemSimulatorEnvironment.run("/bin/sh", ["-c", "exit 4"], options)
    ).rejects.toBeInstanceOf(SimulatorCommandError)
  })

  it("reads files in a temporary directory it removes afterwards", async () => {
    let file = ""
    const contents = await systemSimulatorEnvironment.withTemporaryDirectory(async (directory) => {
      file = join(directory, "screenshot.png")
      await writeFile(file, "png")
      expect(await systemSimulatorEnvironment.isFile(file)).toBe(true)
      expect(await systemSimulatorEnvironment.isFile(directory)).toBe(false)
      expect(await systemSimulatorEnvironment.listDirectory(directory)).toEqual(["screenshot.png"])
      return (await systemSimulatorEnvironment.readFile(file)).toString("utf8")
    })
    expect(contents).toBe("png")
    expect(await systemSimulatorEnvironment.isFile(file)).toBe(false)
    expect(systemSimulatorEnvironment.now()).toBeGreaterThan(0)
  })
})

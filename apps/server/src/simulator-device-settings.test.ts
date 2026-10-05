import { describe, expect, it } from "vitest"

import {
  makeSimulatorDeviceSettings,
  parseAudioRoute,
  parseDeviceSettings
} from "./simulator-device-settings.js"
import { SimulatorCommandError, SimulatorRequestError } from "./simulator-errors.js"
import type { SimulatorEnvironment } from "./simulators.js"

const udid = "2BE37295-E5BE-4B04-A779-19AE566F0429"

// What `devicectl … --json-output` writes under `result`, as Xcode 27's devicectl reports it.
const results: Readonly<Record<string, unknown>> = {
  "device info appearance": {
    deviceIdentifier: udid,
    userInterfaceStyle: "light",
    textSize: "Large",
    increaseContrast: false,
    largerAccessibilitySizesEnabled: false,
    reduceMotion: { enabled: true },
    reduceTransparency: { enabled: false },
    showBorders: { enabled: true },
    colorFilter: { enabled: false },
    liquidGlassOpacity: 0.5,
    lookAndFeel: "Liquid Glass"
  },
  "device info voiceover": { deviceIdentifier: udid, enabled: false, operation: "query" },
  "device info audio": {
    deviceIdentifier: udid,
    volume: 60,
    audioOutputDevice: { device: { _0: "BuiltInSpeakerDevice" } },
    audioInputDevice: { systemDefault: {} }
  },
  "list audioDevices": {
    outputDevices: [{ name: "Mac Studio Speakers", uid: "BuiltInSpeakerDevice" }],
    inputDevices: [{ name: "Studio Display Microphone", uid: "AppleUSBAudioEngine:Apple:1" }]
  }
}

const fakeMac = (supported = true) => {
  const commands: string[][] = []
  const written = new Map<string, Buffer>()
  let now = 0
  const environment: SimulatorEnvironment = {
    platform: "darwin",
    run: async (file, args) => {
      commands.push([file, ...args])
      if (!supported) throw new SimulatorCommandError("Unknown command 'settings'")
      const output = args[args.indexOf("--json-output") + 1] ?? ""
      const key = args.slice(1, args.indexOf("--device") === -1 ? 3 : 4).join(" ")
      written.set(output, Buffer.from(JSON.stringify({ info: {}, result: results[key] ?? {} })))
      return { stdout: Buffer.from("Current Reduce Motion: true\n") }
    },
    readFile: async (path) => written.get(path) ?? Buffer.alloc(0),
    listDirectory: async () => [],
    isFile: async () => false,
    withTemporaryDirectory: (body) => body(`/tmp/devicectl-${commands.length}`),
    now: () => now
  }
  return { environment, commands, advance: (ms: number) => (now += ms) }
}

const devicectl = (commands: ReadonlyArray<ReadonlyArray<string>>) =>
  commands.map((command) => command.slice(1, command.indexOf("--json-output")))

describe("simulator device settings", () => {
  it("reads accessibility, VoiceOver and audio, and the Mac's audio devices", async () => {
    const mac = fakeMac()
    expect(await makeSimulatorDeviceSettings(mac.environment).read(udid)).toEqual({
      liquidGlass: 0.5,
      colorFilter: "none",
      reduceMotion: true,
      showBorders: true,
      reduceTransparency: false,
      voiceOver: false,
      volume: 60,
      audioOutput: "BuiltInSpeakerDevice",
      audioInput: "system",
      audioOutputs: [{ uid: "BuiltInSpeakerDevice", name: "Mac Studio Speakers" }],
      audioInputs: [{ uid: "AppleUSBAudioEngine:Apple:1", name: "Studio Display Microphone" }]
    })
  })

  it("leaves the settings out on an Xcode without them", async () => {
    expect(await makeSimulatorDeviceSettings(fakeMac(false).environment).read(udid)).toEqual({})
  })

  it("lists the Mac's audio devices once in a while, not on every read", async () => {
    const mac = fakeMac()
    const settings = makeSimulatorDeviceSettings(mac.environment)
    await settings.read(udid)
    await settings.read(udid)
    const lists = () => devicectl(mac.commands).filter((command) => command[1] === "list").length
    expect(lists()).toBe(1)
    mac.advance(10_001)
    await settings.read(udid)
    expect(lists()).toBe(2)
  })

  it("applies each group of changes in one devicectl call", async () => {
    const mac = fakeMac()
    await makeSimulatorDeviceSettings(mac.environment).apply(udid, {
      udid,
      reduceMotion: true,
      reduceTransparency: false,
      voiceOver: true,
      volume: 44.6,
      audioOutput: "system",
      audioInput: "AppleUSBAudioEngine:Apple:1"
    })
    expect(devicectl(mac.commands)).toEqual([
      [
        "devicectl",
        "device",
        "settings",
        "appearance",
        "--device",
        udid,
        "--reduce-motion",
        "on",
        "--reduce-transparency",
        "off"
      ],
      ["devicectl", "device", "settings", "voiceover", "--device", udid, "--enable"],
      ["devicectl", "list", "audioDevices"],
      [
        "devicectl",
        "device",
        "settings",
        "audio",
        "--device",
        udid,
        "--volume",
        "45",
        "--output-device",
        "systemDefault",
        "--input-device",
        "AppleUSBAudioEngine:Apple:1"
      ]
    ])
  })

  it("sets Liquid Glass and turns a color filter on with its type, or off", async () => {
    const mac = fakeMac()
    const settings = makeSimulatorDeviceSettings(mac.environment)
    await settings.apply(udid, { udid, liquidGlass: 0.333, colorFilter: "deuteranopia" })
    await settings.apply(udid, { udid, colorFilter: "none" })
    expect(devicectl(mac.commands)).toEqual([
      [
        "devicectl",
        "device",
        "settings",
        "appearance",
        "--device",
        udid,
        "--liquid-glass-opacity",
        "0.33",
        "--color-filter",
        "on",
        "--color-filter-type",
        "deuteranopia"
      ],
      ["devicectl", "device", "settings", "appearance", "--device", udid, "--color-filter", "off"]
    ])
  })

  it("reads each color filter by name and leaves out what it can't read", () => {
    const filter = (colorFilter: unknown, liquidGlassOpacity?: unknown) =>
      parseDeviceSettings({ colorFilter, liquidGlassOpacity }, undefined, undefined, undefined)
    expect(filter({ enabled: true, filterType: { name: "Protanopia" }, intensity: 0.6 })).toEqual({
      colorFilter: "protanopia"
    })
    expect(filter({ enabled: true, filterType: { name: "Tritanopia" } }, 1)).toEqual({
      liquidGlass: 1,
      colorFilter: "tritanopia"
    })
    expect(filter({ enabled: true, filterType: { name: "Grayscale" } }, 0)).toEqual({
      liquidGlass: 0,
      colorFilter: "grayscale"
    })
    // A filter this version doesn't know, an enabled one without a type, or an opacity out of range.
    expect(filter({ enabled: true, filterType: { name: "ColorTint" } }, 1.5)).toEqual({})
    expect(filter({ enabled: true }, "0.5")).toEqual({})
    expect(filter(undefined)).toEqual({})
  })

  it("refuses an audio device the Mac doesn't have in that direction", async () => {
    const mac = fakeMac()
    const settings = makeSimulatorDeviceSettings(mac.environment)
    await expect(
      settings.apply(udid, { udid, audioOutput: "AppleUSBAudioEngine:Apple:1" })
    ).rejects.toBeInstanceOf(SimulatorRequestError)
    expect(devicectl(mac.commands).some((command) => command[2] === "settings")).toBe(false)
  })

  it("reads audio routes and tolerates unexpected shapes", () => {
    expect(parseAudioRoute({ systemDefault: {} })).toBe("system")
    expect(parseAudioRoute({ device: { _0: "Speakers" } })).toBe("Speakers")
    expect(parseAudioRoute("Speakers")).toBeUndefined()
    expect(parseDeviceSettings(undefined, { enabled: "yes" }, { volume: 400 }, [])).toEqual({})
  })

  it("takes bare booleans and skips audio devices it can't name", () => {
    expect(
      parseDeviceSettings(
        { showBorders: false },
        true,
        { audioOutputDevice: { device: { _0: 7 } } },
        {
          outputDevices: [{ uid: "Speakers", name: "Speakers" }, { uid: 1 }, "junk"],
          inputDevices: {}
        }
      )
    ).toEqual({
      showBorders: false,
      voiceOver: true,
      audioOutputs: [{ uid: "Speakers", name: "Speakers" }],
      audioInputs: []
    })
  })

  it("turns borders on and VoiceOver off", async () => {
    const mac = fakeMac()
    await makeSimulatorDeviceSettings(mac.environment).apply(udid, {
      udid,
      showBorders: true,
      voiceOver: false
    })
    expect(devicectl(mac.commands)).toEqual([
      ["devicectl", "device", "settings", "appearance", "--device", udid, "--show-borders", "on"],
      ["devicectl", "device", "settings", "voiceover", "--device", udid, "--disable"]
    ])
  })
})

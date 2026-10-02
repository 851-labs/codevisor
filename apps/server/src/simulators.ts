import { execFile } from "node:child_process"
import { mkdtemp, readFile, readdir, rm, stat } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type {
  SimulatorChrome,
  SimulatorDevice,
  SimulatorDeviceTypeDetail,
  SimulatorList,
  SimulatorSettings,
  SimulatorSettingsChange
} from "@codevisor/api"

import { makeSimulatorDeviceSettings } from "./simulator-device-settings.js"
import { SimulatorCommandError, SimulatorRequestError } from "./simulator-errors.js"
import {
  chromeImageNames,
  parseDisplays,
  parseFeatures,
  parseSimulatorList,
  stringField,
  type RawList
} from "./simulator-parsing.js"

/// Apple simulators on this Mac, read and changed through `xcrun simctl`.
/// Nothing here needs the native app: video, input, rotation and posture go
/// through the app's screen-sharing host instead.

export interface SimulatorCommandResult {
  readonly stdout: Buffer
}

export interface SimulatorEnvironment {
  readonly platform: NodeJS.Platform
  readonly run: (
    file: string,
    args: ReadonlyArray<string>,
    options: { readonly timeoutMs: number; readonly maxBytes: number }
  ) => Promise<SimulatorCommandResult>
  readonly readFile: (path: string) => Promise<Buffer>
  readonly listDirectory: (path: string) => Promise<ReadonlyArray<string>>
  readonly isFile: (path: string) => Promise<boolean>
  /// Runs `body` with a fresh directory that's removed afterwards (simctl writes screenshots
  /// only to files).
  readonly withTemporaryDirectory: <T>(body: (directory: string) => Promise<T>) => Promise<T>
  readonly now: () => number
}

export const systemSimulatorEnvironment: SimulatorEnvironment = {
  platform: process.platform,
  run: (file, args, options) =>
    new Promise((resolve, reject) => {
      execFile(
        file,
        [...args],
        { encoding: "buffer", timeout: options.timeoutMs, maxBuffer: options.maxBytes },
        (error, stdout, stderr) => {
          if (error) {
            reject(new SimulatorCommandError(stderr.toString("utf8").trim() || error.message))
            return
          }
          resolve({ stdout })
        }
      )
    }),
  readFile: (path) => readFile(path),
  listDirectory: (path) => readdir(path),
  isFile: async (path) => {
    try {
      return (await stat(path)).isFile()
    } catch {
      return false
    }
  },
  withTemporaryDirectory: async (body) => {
    const directory = await mkdtemp(join(tmpdir(), "codevisor-simulator-"))
    try {
      return await body(directory)
    } finally {
      await rm(directory, { recursive: true, force: true })
    }
  },
  now: () => Date.now()
}

export { SimulatorCommandError, SimulatorRequestError }

export interface Simulators {
  /// Whether Xcode's simulators work here and the native app is running to
  /// stream them. Cached; a failed probe is retried.
  readonly available: () => Promise<boolean>
  readonly list: () => Promise<SimulatorList>
  readonly deviceType: (identifier: string) => Promise<SimulatorDeviceTypeDetail>
  readonly chrome: (identifier: string) => Promise<SimulatorChrome>
  readonly perform: (
    udid: string,
    action: "boot" | "shutdown" | "restart" | "delete"
  ) => Promise<void>
  readonly create: (name: string, deviceType: string, runtime: string) => Promise<string>
  readonly rename: (udid: string, name: string) => Promise<void>
  readonly settings: (udid: string) => Promise<SimulatorSettings>
  readonly changeSettings: (change: SimulatorSettingsChange) => Promise<SimulatorSettings>
  readonly screenshot: (udid: string) => Promise<Buffer>
}

const udidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const identifierPattern = /^[A-Za-z0-9.\-_]{1,200}$/
const availableTTL = 5 * 60_000
const unavailableTTL = 30_000

export const chromeDirectories = ["/Library/Developer/DeviceKit/Chrome"]
export const maskDirectories = ["/Library/Developer/DeviceKit/FramebufferMasks"]

const locationScenarios: Readonly<Record<SimulatorSettings["location"], string | undefined>> = {
  none: undefined,
  apple: "Apple",
  "city-run": "City Run",
  "city-bicycle-ride": "City Bicycle Ride",
  "freeway-drive": "Freeway Drive"
}

const contentSizes = new Set<string>([
  "extra-small",
  "small",
  "medium",
  "large",
  "extra-large",
  "extra-extra-large",
  "extra-extra-extra-large",
  "accessibility-medium",
  "accessibility-large",
  "accessibility-extra-large",
  "accessibility-extra-extra-large",
  "accessibility-extra-extra-extra-large"
])

/// `nativeHost` says whether the app that streams simulators is running.
export const makeSimulators = (
  environment: SimulatorEnvironment,
  nativeHost: () => boolean = () => true
): Simulators => {
  let probe: { readonly value: boolean; readonly at: number } | undefined
  let probing: Promise<boolean> | undefined
  const deviceTypeCache = new Map<string, SimulatorDeviceTypeDetail>()
  const chromeCache = new Map<string, SimulatorChrome>()

  const simctl = async (
    args: ReadonlyArray<string>,
    timeoutMs = 20_000,
    maxBytes = 16 * 1024 * 1024
  ): Promise<Buffer> =>
    (await environment.run("xcrun", ["simctl", ...args], { timeoutMs, maxBytes })).stdout

  const rawList = async (): Promise<RawList> =>
    JSON.parse((await simctl(["list", "-j"])).toString("utf8")) as RawList

  const plistJSON = async (path: string): Promise<Record<string, unknown>> =>
    JSON.parse(
      (
        await environment.run("plutil", ["-convert", "json", "-o", "-", path], {
          timeoutMs: 10_000,
          maxBytes: 4 * 1024 * 1024
        })
      ).stdout.toString("utf8")
    ) as Record<string, unknown>

  const requireUDID = (udid: string): string => {
    if (!udidPattern.test(udid)) throw new SimulatorRequestError(400, "Invalid simulator id")
    return udid.toUpperCase()
  }

  const requireDevice = async (udid: string): Promise<SimulatorDevice> => {
    const id = requireUDID(udid)
    const device = parseSimulatorList(await rawList()).devices.find((item) => item.udid === id)
    if (device === undefined) throw new SimulatorRequestError(404, "Simulator not found")
    return device
  }

  const uiSetting = async (udid: string, option: string): Promise<string | undefined> => {
    try {
      const value = (await simctl(["ui", udid, option], 10_000)).toString("utf8").trim()
      return value === "unsupported" || value === "unknown" || value === "" ? undefined : value
    } catch {
      return undefined
    }
  }

  // Location isn't readable back from simctl; remember what this server set.
  const locations = new Map<string, SimulatorSettings["location"]>()

  const deviceSettings = makeSimulatorDeviceSettings(environment)

  const settings = async (udid: string): Promise<SimulatorSettings> => {
    const id = requireUDID(udid)
    const [appearance, contentSize, contrast, more] = await Promise.all([
      uiSetting(id, "appearance"),
      uiSetting(id, "content_size"),
      uiSetting(id, "increase_contrast"),
      deviceSettings.read(id)
    ])
    return {
      ...more,
      ...(appearance === "light" || appearance === "dark" ? { appearance } : {}),
      ...(contentSize !== undefined && contentSizes.has(contentSize)
        ? { contentSize: contentSize as SimulatorSettings["contentSize"] & string }
        : {}),
      ...(contrast === "enabled" || contrast === "disabled"
        ? { increaseContrast: contrast === "enabled" }
        : {}),
      location: locations.get(id) ?? "none"
    }
  }

  const readMasks = async (ids: ReadonlyArray<string>, bundle: string) => {
    const masks = new Map<string, string>()
    for (const id of ids) {
      if (!identifierPattern.test(id)) continue
      for (const directory of [join(bundle, "Contents/Resources"), ...maskDirectories]) {
        const path = join(directory, `${id}.pdf`)
        if (await environment.isFile(path)) {
          masks.set(id, (await environment.readFile(path)).toString("base64"))
          break
        }
      }
    }
    return masks
  }

  return {
    available: () => {
      if (environment.platform !== "darwin" || !nativeHost()) return Promise.resolve(false)
      const now = environment.now()
      if (probe !== undefined && now - probe.at < (probe.value ? availableTTL : unavailableTTL))
        return Promise.resolve(probe.value)
      probing ??= (async () => {
        let value = false
        try {
          // Command Line Tools alone have no simctl; a full Xcode lists runtimes.
          const list = parseSimulatorList(await rawList())
          value = list.runtimes.length > 0
        } catch {
          value = false
        }
        probe = { value, at: environment.now() }
        probing = undefined
        return value
      })()
      return probing
    },

    list: async () => parseSimulatorList(await rawList()),

    deviceType: async (identifier) => {
      const cached = deviceTypeCache.get(identifier)
      if (cached !== undefined) return cached
      const type = (await rawList()).devicetypes?.find((item) => item.identifier === identifier)
      if (type?.bundlePath === undefined || type.name === undefined)
        throw new SimulatorRequestError(404, "Device type not found")
      const resources = join(type.bundlePath, "Contents/Resources")
      const profile = await plistJSON(join(resources, "profile.plist"))
      let rawDisplays: unknown = []
      try {
        const capabilities = await plistJSON(join(resources, "capabilities.plist"))
        rawDisplays = (capabilities["capabilities"] as Record<string, unknown> | undefined)?.[
          "displays"
        ]
      } catch {
        rawDisplays = []
      }
      const maskIds = Array.isArray(rawDisplays)
        ? rawDisplays.flatMap((entry: Record<string, unknown>) => {
            const id = stringField(entry, "framebufferMaskIdentifier")
            return id === undefined ? [] : [id]
          })
        : []
      const chromeIdentifier = stringField(profile, "chromeIdentifier")
      const detail: SimulatorDeviceTypeDetail = {
        identifier,
        name: type.name,
        productFamily: type.productFamily ?? "iPhone",
        features: parseFeatures(profile),
        ...(chromeIdentifier === undefined ? {} : { chromeIdentifier }),
        displays: parseDisplays(rawDisplays, await readMasks(maskIds, type.bundlePath))
      }
      deviceTypeCache.set(identifier, detail)
      return detail
    },

    chrome: async (identifier) => {
      const cached = chromeCache.get(identifier)
      if (cached !== undefined) return cached
      const name = identifier.replace(/^com\.apple\.dt\.devicekit\.chrome\./, "")
      if (!identifierPattern.test(name)) throw new SimulatorRequestError(400, "Invalid chrome")
      for (const directory of chromeDirectories) {
        const resources = join(directory, `${name}.devicechrome`, "Contents/Resources")
        const definitionPath = join(resources, "chrome.json")
        if (!(await environment.isFile(definitionPath))) continue
        const definition = JSON.parse(
          (await environment.readFile(definitionPath)).toString("utf8")
        ) as unknown
        const files = new Set(await environment.listDirectory(resources))
        const images: Record<string, string> = {}
        for (const image of chromeImageNames(definition)) {
          const file = `${image}.pdf`
          if (!files.has(file)) continue
          images[image] = (await environment.readFile(join(resources, file))).toString("base64")
        }
        const chrome = { identifier, definition, images }
        chromeCache.set(identifier, chrome)
        return chrome
      }
      throw new SimulatorRequestError(404, "Device chrome not found")
    },

    perform: async (udid, action) => {
      const device = await requireDevice(udid)
      switch (action) {
        case "boot":
          if (device.state !== "Booted") await simctl(["boot", device.udid], 120_000)
          return
        case "shutdown":
          if (device.state !== "Shutdown") await simctl(["shutdown", device.udid], 60_000)
          return
        case "restart":
          if (device.state !== "Shutdown") await simctl(["shutdown", device.udid], 60_000)
          await simctl(["boot", device.udid], 120_000)
          return
        case "delete":
          if (device.state !== "Shutdown") await simctl(["shutdown", device.udid], 60_000)
          await simctl(["delete", device.udid], 60_000)
          return
      }
    },

    create: async (name, deviceType, runtime) => {
      const trimmed = name.trim()
      if (trimmed.length === 0 || trimmed.length > 120)
        throw new SimulatorRequestError(400, "Choose a name for the simulator")
      if (!identifierPattern.test(deviceType) || !identifierPattern.test(runtime))
        throw new SimulatorRequestError(400, "Invalid device type or runtime")
      const created = (await simctl(["create", trimmed, deviceType, runtime], 60_000))
        .toString("utf8")
        .trim()
      if (!udidPattern.test(created)) throw new SimulatorCommandError("simctl create failed")
      return created.toUpperCase()
    },

    rename: async (udid, name) => {
      const device = await requireDevice(udid)
      const trimmed = name.trim()
      if (trimmed.length === 0 || trimmed.length > 120)
        throw new SimulatorRequestError(400, "Choose a name for the simulator")
      await simctl(["rename", device.udid, trimmed])
    },

    settings,

    changeSettings: async (change) => {
      const id = requireUDID(change.udid)
      if (change.appearance !== undefined) await simctl(["ui", id, "appearance", change.appearance])
      if (change.contentSize !== undefined)
        await simctl(["ui", id, "content_size", change.contentSize])
      if (change.increaseContrast !== undefined)
        await simctl([
          "ui",
          id,
          "increase_contrast",
          change.increaseContrast ? "enabled" : "disabled"
        ])
      if (change.location !== undefined) {
        const scenario = locationScenarios[change.location]
        await simctl(
          scenario === undefined ? ["location", id, "clear"] : ["location", id, "run", scenario]
        )
        locations.set(id, change.location)
      }
      await deviceSettings.apply(id, change)
      return settings(id)
    },

    screenshot: async (udid) => {
      const id = requireUDID(udid)
      return environment.withTemporaryDirectory(async (directory) => {
        const path = join(directory, "screenshot.png")
        await simctl(["io", id, "screenshot", "--type=png", path])
        return environment.readFile(path)
      })
    }
  }
}

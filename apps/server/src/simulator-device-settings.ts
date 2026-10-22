import { join } from "node:path"

import type {
  SimulatorAudioDevice,
  SimulatorSettings,
  SimulatorSettingsChange
} from "@codevisor/api"

import { SimulatorRequestError } from "./simulator-errors.js"
import type { SimulatorEnvironment } from "./simulators.js"
import { isRecord } from "./unknown-values.js"

export type SimulatorDeviceSettings = Pick<
  SimulatorSettings,
  | "liquidGlass"
  | "colorFilter"
  | "reduceMotion"
  | "showBorders"
  | "reduceTransparency"
  | "voiceOver"
  | "volume"
  | "audioOutput"
  | "audioInput"
  | "audioOutputs"
  | "audioInputs"
>

export const systemAudioRoute = "system"

const audioDevicesTTL = 10_000

const record = (value: unknown): Readonly<Record<string, unknown>> | undefined =>
  isRecord(value) ? value : undefined

const enabled = (value: unknown): boolean | undefined => {
  if (typeof value === "boolean") return value
  const flag = record(value)?.["enabled"]
  return typeof flag === "boolean" ? flag : undefined
}

const colorFilters: Readonly<Record<string, ColorFilter>> = {
  Protanopia: "protanopia",
  Deuteranopia: "deuteranopia",
  Tritanopia: "tritanopia",
  Grayscale: "grayscale"
}

type ColorFilter = NonNullable<SimulatorSettings["colorFilter"]>

const parseColorFilter = (value: unknown): ColorFilter | undefined => {
  const filter = record(value)
  const on = filter?.["enabled"]
  if (on === false) return "none"
  const name = record(filter?.["filterType"])?.["name"]
  return on === true && typeof name === "string" ? colorFilters[name] : undefined
}

export const parseAudioRoute = (value: unknown): string | undefined => {
  const route = record(value)
  if (route === undefined) return undefined
  if (record(route["systemDefault"]) !== undefined) return systemAudioRoute
  const uid = record(route["device"])?.["_0"]
  return typeof uid === "string" ? uid : undefined
}

const parseAudioDevices = (value: unknown): ReadonlyArray<SimulatorAudioDevice> =>
  Array.isArray(value)
    ? value.flatMap((entry) => {
        const device = record(entry)
        const uid = device?.["uid"]
        const name = device?.["name"]
        return typeof uid === "string" && typeof name === "string" ? [{ uid, name }] : []
      })
    : []

export const parseDeviceSettings = (
  appearance: unknown,
  voiceOver: unknown,
  audio: unknown,
  devices: unknown
): SimulatorDeviceSettings => {
  const look = record(appearance)
  const sound = record(audio)
  const hosts = record(devices)
  const liquidGlass = look?.["liquidGlassOpacity"]
  const colorFilter = parseColorFilter(look?.["colorFilter"])
  const reduceMotion = enabled(look?.["reduceMotion"])
  const showBorders = enabled(look?.["showBorders"])
  const reduceTransparency = enabled(look?.["reduceTransparency"])
  const spoken = enabled(voiceOver)
  const volume = sound?.["volume"]
  const audioOutput = parseAudioRoute(sound?.["audioOutputDevice"])
  const audioInput = parseAudioRoute(sound?.["audioInputDevice"])
  return {
    ...(typeof liquidGlass === "number" && liquidGlass >= 0 && liquidGlass <= 1
      ? { liquidGlass }
      : {}),
    ...(colorFilter === undefined ? {} : { colorFilter }),
    ...(reduceMotion === undefined ? {} : { reduceMotion }),
    ...(showBorders === undefined ? {} : { showBorders }),
    ...(reduceTransparency === undefined ? {} : { reduceTransparency }),
    ...(spoken === undefined ? {} : { voiceOver: spoken }),
    ...(typeof volume === "number" && volume >= 0 && volume <= 100 ? { volume } : {}),
    ...(audioOutput === undefined ? {} : { audioOutput }),
    ...(audioInput === undefined ? {} : { audioInput }),
    ...(hosts === undefined
      ? {}
      : {
          audioOutputs: parseAudioDevices(hosts["outputDevices"]),
          audioInputs: parseAudioDevices(hosts["inputDevices"])
        })
  }
}

const colorFilterArguments = (change: SimulatorSettingsChange) => {
  if (change.colorFilter === undefined) return []
  if (change.colorFilter === "none") return ["--color-filter", "off"]
  return ["--color-filter", "on", "--color-filter-type", change.colorFilter]
}

const optional = async (read: () => Promise<unknown>): Promise<unknown> => {
  try {
    return await read()
  } catch {
    return undefined
  }
}

const onOff = (value: boolean) => (value ? "on" : "off")

export const makeSimulatorDeviceSettings = (environment: SimulatorEnvironment) => {
  const devicectl = (args: ReadonlyArray<string>): Promise<unknown> =>
    environment.withTemporaryDirectory(async (directory) => {
      const path = join(directory, "result.json")
      await environment.run("xcrun", ["devicectl", ...args, "--json-output", path], {
        timeoutMs: 20_000,
        maxBytes: 4 * 1024 * 1024
      })
      return record(JSON.parse((await environment.readFile(path)).toString("utf8")))?.["result"]
    })

  let devices: { readonly value: unknown; readonly at: number } | undefined
  const audioDevices = async (): Promise<unknown> => {
    if (devices !== undefined && environment.now() - devices.at < audioDevicesTTL)
      return devices.value
    const value = await devicectl(["list", "audioDevices"])
    devices = { value, at: environment.now() }
    return value
  }

  const read = async (udid: string): Promise<SimulatorDeviceSettings> => {
    const [appearance, voiceOver, audio, hosts] = await Promise.all([
      optional(() => devicectl(["device", "info", "appearance", "--device", udid])),
      optional(() => devicectl(["device", "info", "voiceover", "--device", udid])),
      optional(() => devicectl(["device", "info", "audio", "--device", udid])),
      optional(audioDevices)
    ])
    return parseDeviceSettings(appearance, voiceOver, audio, hosts)
  }

  const route = async (uid: string, direction: "outputDevices" | "inputDevices") => {
    if (uid === systemAudioRoute) return "systemDefault"
    const known = parseAudioDevices(record(await audioDevices())?.[direction])
    if (!known.some((device) => device.uid === uid))
      throw new SimulatorRequestError(400, "That audio device isn't on this Mac")
    return uid
  }

  const apply = async (udid: string, change: SimulatorSettingsChange): Promise<void> => {
    const appearance = [
      ...(change.liquidGlass === undefined
        ? []
        : ["--liquid-glass-opacity", String(Math.round(change.liquidGlass * 100) / 100)]),
      ...colorFilterArguments(change),
      ...(change.reduceMotion === undefined ? [] : ["--reduce-motion", onOff(change.reduceMotion)]),
      ...(change.showBorders === undefined ? [] : ["--show-borders", onOff(change.showBorders)]),
      ...(change.reduceTransparency === undefined
        ? []
        : ["--reduce-transparency", onOff(change.reduceTransparency)])
    ]
    if (appearance.length > 0)
      await devicectl(["device", "settings", "appearance", "--device", udid, ...appearance])
    if (change.voiceOver !== undefined)
      await devicectl([
        "device",
        "settings",
        "voiceover",
        "--device",
        udid,
        change.voiceOver ? "--enable" : "--disable"
      ])
    const audio: string[] =
      change.volume === undefined ? [] : ["--volume", String(Math.round(change.volume))]
    if (change.audioOutput !== undefined) {
      audio.push("--output-device", await route(change.audioOutput, "outputDevices"))
    }
    if (change.audioInput !== undefined) {
      audio.push("--input-device", await route(change.audioInput, "inputDevices"))
    }
    if (audio.length > 0)
      await devicectl(["device", "settings", "audio", "--device", udid, ...audio])
  }

  return { read, apply }
}

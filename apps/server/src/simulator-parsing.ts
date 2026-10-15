import type {
  SimulatorDevice,
  SimulatorDeviceType,
  SimulatorDisplay,
  SimulatorList,
  SimulatorRuntime
} from "@codevisor/api"
import { Schema } from "effect"

import { field, recordField } from "./unknown-values.js"

const udidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

const RawDevice = Schema.Struct({
  udid: Schema.optionalKey(Schema.String),
  name: Schema.optionalKey(Schema.String),
  state: Schema.optionalKey(Schema.String),
  isAvailable: Schema.optionalKey(Schema.Boolean),
  deviceTypeIdentifier: Schema.optionalKey(Schema.String),
  lastBootedAt: Schema.optionalKey(Schema.String)
})
type RawDevice = typeof RawDevice.Type

const RawDeviceType = Schema.Struct({
  identifier: Schema.optionalKey(Schema.String),
  name: Schema.optionalKey(Schema.String),
  productFamily: Schema.optionalKey(Schema.String),
  bundlePath: Schema.optionalKey(Schema.String)
})

const RawRuntime = Schema.Struct({
  identifier: Schema.optionalKey(Schema.String),
  name: Schema.optionalKey(Schema.String),
  platform: Schema.optionalKey(Schema.String),
  version: Schema.optionalKey(Schema.String),
  isAvailable: Schema.optionalKey(Schema.Boolean),
  supportedDeviceTypes: Schema.optionalKey(
    Schema.Array(Schema.Struct({ identifier: Schema.optionalKey(Schema.String) }))
  )
})

const RawList = Schema.Struct({
  devices: Schema.optionalKey(Schema.Record(Schema.String, Schema.Array(RawDevice))),
  devicetypes: Schema.optionalKey(Schema.Array(RawDeviceType)),
  runtimes: Schema.optionalKey(Schema.Array(RawRuntime))
})
export type RawList = typeof RawList.Type

export const decodeRawList = Schema.decodeUnknownSync(RawList)

const simulatorDeviceTypes = (raw: RawList): SimulatorDeviceType[] =>
  (raw.devicetypes ?? []).flatMap((type) =>
    type.identifier === undefined || type.name === undefined
      ? []
      : [
          {
            identifier: type.identifier,
            name: type.name,
            productFamily: type.productFamily ?? "iPhone"
          }
        ]
  )

const simulatorRuntimes = (raw: RawList): SimulatorRuntime[] =>
  (raw.runtimes ?? []).flatMap((runtime) =>
    runtime.identifier === undefined || runtime.isAvailable === false
      ? []
      : [
          {
            identifier: runtime.identifier,
            name: runtime.name ?? runtime.identifier,
            platform: runtime.platform ?? platformOf(runtime.identifier),
            version: runtime.version ?? "",
            deviceTypeIdentifiers: (runtime.supportedDeviceTypes ?? []).flatMap((type) =>
              type.identifier === undefined ? [] : [type.identifier]
            )
          }
        ]
  )

const collectSimulatorDevices = (
  raw: RawList,
  runtimeById: ReadonlyMap<string, SimulatorRuntime>,
  typeById: ReadonlyMap<string, SimulatorDeviceType>
): SimulatorDevice[] => {
  const devices: SimulatorDevice[] = []
  for (const [runtimeId, entries] of Object.entries(raw.devices ?? {})) {
    const runtime = runtimeById.get(runtimeId)
    if (runtime === undefined) continue
    for (const device of entries) {
      if (device.isAvailable === false || !udidPattern.test(device.udid ?? "")) continue
      const typeId = device.deviceTypeIdentifier ?? ""
      devices.push(simulatorListDevice(device, runtime, typeId, typeById))
    }
  }
  return devices
}

const simulatorListDevice = (
  device: RawDevice,
  runtime: SimulatorRuntime,
  typeId: string,
  typeById: ReadonlyMap<string, SimulatorDeviceType>
): SimulatorDevice => ({
  udid: device.udid!.toUpperCase(),
  name: device.name ?? "Simulator",
  state: device.state ?? "Shutdown",
  runtime: {
    identifier: runtime.identifier,
    name: runtime.name,
    platform: runtime.platform,
    version: runtime.version
  },
  deviceType: typeById.get(typeId) ?? {
    identifier: typeId,
    name: typeId.slice(typeId.lastIndexOf(".") + 1),
    productFamily: "iPhone"
  },
  ...(device.lastBootedAt === undefined ? {} : { lastBootedAt: device.lastBootedAt })
})

export const parseSimulatorList = (raw: RawList): SimulatorList => {
  const deviceTypes = simulatorDeviceTypes(raw)
  const typeById = new Map(deviceTypes.map((type) => [type.identifier, type]))
  const runtimes = simulatorRuntimes(raw)
  const runtimeById = new Map(runtimes.map((runtime) => [runtime.identifier, runtime]))
  const devices = collectSimulatorDevices(raw, runtimeById, typeById)
  devices.sort(
    (a, b) =>
      familyOrder(a.deviceType.productFamily) - familyOrder(b.deviceType.productFamily) ||
      a.name.localeCompare(b.name, undefined, { numeric: true }) ||
      b.runtime.version.localeCompare(a.runtime.version, undefined, { numeric: true })
  )
  return { devices, deviceTypes, runtimes }
}

const families = ["iPhone", "iPad", "Apple Watch", "Apple TV", "Apple Vision"]
const familyOrder = (family: string): number => {
  const index = families.indexOf(family)
  return index === -1 ? families.length : index
}

const platformOf = (runtimeIdentifier: string): string =>
  runtimeIdentifier.replace(/^com\.apple\.CoreSimulator\.SimRuntime\./, "").replace(/-.*$/, "")

export const parseDisplays = (
  raw: unknown,
  masks: ReadonlyMap<string, string>
): SimulatorDisplay[] => {
  if (!Array.isArray(raw)) return []
  return raw.flatMap((entry: Record<string, unknown>) => {
    const width = numberField(entry, "width")
    const height = numberField(entry, "height")
    if (width === undefined || height === undefined) return []
    const integrated = entry["displayType"] === "integrated"
    const powered = entry["powerState"] === 1
    if (!integrated && !powered) return []
    const maskId = stringField(entry, "framebufferMaskIdentifier")
    const mask = maskId === undefined ? undefined : masks.get(maskId)
    const chromeIdentifier = stringField(entry, "chromeIdentifier")
    return [
      {
        name: stringField(entry, "deviceName") ?? "primary",
        width,
        height,
        scale: numberField(entry, "scale") ?? 1,
        cornerRadii: [
          numberField(entry, "cornerRadiusUL") ?? 0,
          numberField(entry, "cornerRadiusUR") ?? 0,
          numberField(entry, "cornerRadiusLL") ?? 0,
          numberField(entry, "cornerRadiusLR") ?? 0
        ],
        ...(chromeIdentifier === undefined ? {} : { chromeIdentifier }),
        ...(mask === undefined ? {} : { mask }),
        hasDigitizer: entry["hasDigitizer"] === true
      }
    ]
  })
}

export const numberField = (entry: Record<string, unknown>, key: string): number | undefined =>
  typeof entry[key] === "number" && Number.isFinite(entry[key]) ? entry[key] : undefined
export const stringField = (entry: Record<string, unknown>, key: string): string | undefined =>
  typeof entry[key] === "string" && entry[key].length > 0 ? entry[key] : undefined

export const parseFeatures = (profile: Record<string, unknown>): string[] => {
  const features = new Set<string>()
  for (const key of ["supportedFeatures", "supportedFeaturesConditionalOnRuntime"]) {
    const table = profile[key]
    if (table === null || typeof table !== "object") continue
    for (const [name, value] of Object.entries(table)) {
      if (value === true || value === "1") features.add(name)
    }
  }
  return [...features].toSorted()
}

export const chromeImageNames = (definition: unknown): string[] => {
  const names = new Set<string>()
  for (const value of Object.values(recordField(definition, "images"))) {
    if (typeof value === "string") names.add(value)
  }
  const inputs = field(definition, "inputs")
  for (const input of Array.isArray(inputs) ? inputs : []) {
    for (const key of ["image", "imageDown"]) {
      const value = field(input, key)
      if (typeof value === "string") names.add(value)
    }
  }
  return [...names].filter((name) => /^[A-Za-z0-9 _\-.]{1,120}$/.test(name))
}

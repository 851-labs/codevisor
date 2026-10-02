import type {
  SimulatorDevice,
  SimulatorDeviceType,
  SimulatorDisplay,
  SimulatorList,
  SimulatorRuntime
} from "@codevisor/api"

/// simctl and device-type plist output, reduced to what clients show.

const udidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export interface RawList {
  readonly devices?: Record<string, ReadonlyArray<RawDevice>>
  readonly devicetypes?: ReadonlyArray<RawDeviceType>
  readonly runtimes?: ReadonlyArray<RawRuntime>
}

export interface RawDevice {
  readonly udid?: string
  readonly name?: string
  readonly state?: string
  readonly isAvailable?: boolean
  readonly deviceTypeIdentifier?: string
  readonly lastBootedAt?: string
}

export interface RawDeviceType {
  readonly identifier?: string
  readonly name?: string
  readonly productFamily?: string
  readonly bundlePath?: string
}

export interface RawRuntime {
  readonly identifier?: string
  readonly name?: string
  readonly platform?: string
  readonly version?: string
  readonly isAvailable?: boolean
  readonly supportedDeviceTypes?: ReadonlyArray<{ readonly identifier?: string }>
}

/// simctl's JSON, reduced to what clients show. Unavailable devices and
/// runtimes (a runtime that was deleted) are left out.
export const parseSimulatorList = (raw: RawList): SimulatorList => {
  const deviceTypes: SimulatorDeviceType[] = (raw.devicetypes ?? []).flatMap((type) =>
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
  const typeById = new Map(deviceTypes.map((type) => [type.identifier, type]))
  const runtimes: SimulatorRuntime[] = (raw.runtimes ?? []).flatMap((runtime) =>
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
  const runtimeById = new Map(runtimes.map((runtime) => [runtime.identifier, runtime]))
  const devices: SimulatorDevice[] = []
  for (const [runtimeId, entries] of Object.entries(raw.devices ?? {})) {
    const runtime = runtimeById.get(runtimeId)
    if (runtime === undefined) continue
    for (const device of entries) {
      if (device.isAvailable === false || !udidPattern.test(device.udid ?? "")) continue
      const typeId = device.deviceTypeIdentifier ?? ""
      devices.push({
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
    }
  }
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

/// A device type's displays from its capabilities plist. Only powered,
/// integrated screens are the device's own; an Apple TV's single screen is
/// its powered TV output.
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

/// The features a profile turns on, conditional ones included.
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

/// The image names a chrome.json refers to: its frame slices and every
/// input's normal and pressed images.
export const chromeImageNames = (definition: unknown): string[] => {
  const names = new Set<string>()
  const record = definition as {
    images?: Record<string, unknown>
    inputs?: ReadonlyArray<Record<string, unknown>>
    postures?: unknown
  }
  for (const value of Object.values(record.images ?? {})) {
    if (typeof value === "string") names.add(value)
  }
  for (const input of record.inputs ?? []) {
    for (const key of ["image", "imageDown"]) {
      const value = input[key]
      if (typeof value === "string") names.add(value)
    }
  }
  return [...names].filter((name) => /^[A-Za-z0-9 _\-.]{1,120}$/.test(name))
}

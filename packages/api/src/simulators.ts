import { Schema } from "effect"

export const SimulatorRuntime = Schema.Struct({
  identifier: Schema.String,
  name: Schema.String,
  platform: Schema.String,
  version: Schema.String,
  deviceTypeIdentifiers: Schema.Array(Schema.String)
})
export type SimulatorRuntime = typeof SimulatorRuntime.Type

export const SimulatorDeviceType = Schema.Struct({
  identifier: Schema.String,
  name: Schema.String,
  productFamily: Schema.String
})
export type SimulatorDeviceType = typeof SimulatorDeviceType.Type

export const SimulatorDevice = Schema.Struct({
  udid: Schema.String,
  name: Schema.String,
  state: Schema.String,
  runtime: Schema.Struct({
    identifier: Schema.String,
    name: Schema.String,
    platform: Schema.String,
    version: Schema.String
  }),
  deviceType: SimulatorDeviceType,
  lastBootedAt: Schema.optional(Schema.String)
})
export type SimulatorDevice = typeof SimulatorDevice.Type

export const SimulatorList = Schema.Struct({
  devices: Schema.Array(SimulatorDevice),
  deviceTypes: Schema.Array(SimulatorDeviceType),
  runtimes: Schema.Array(SimulatorRuntime)
})
export type SimulatorList = typeof SimulatorList.Type

export const SimulatorDisplay = Schema.Struct({
  name: Schema.String,
  width: Schema.Number,
  height: Schema.Number,
  scale: Schema.Number,
  cornerRadii: Schema.Array(Schema.Number),
  chromeIdentifier: Schema.optional(Schema.String),
  mask: Schema.optional(Schema.String),
  hasDigitizer: Schema.Boolean
})
export type SimulatorDisplay = typeof SimulatorDisplay.Type

export const SimulatorDeviceTypeDetail = Schema.Struct({
  identifier: Schema.String,
  name: Schema.String,
  productFamily: Schema.String,
  features: Schema.Array(Schema.String),
  chromeIdentifier: Schema.optional(Schema.String),
  displays: Schema.Array(SimulatorDisplay)
})
export type SimulatorDeviceTypeDetail = typeof SimulatorDeviceTypeDetail.Type

export const SimulatorChrome = Schema.Struct({
  identifier: Schema.String,
  definition: Schema.Unknown,
  images: Schema.Record(Schema.String, Schema.String)
})
export type SimulatorChrome = typeof SimulatorChrome.Type

export const SimulatorDeviceAction = Schema.Struct({
  udid: Schema.String,
  action: Schema.Literals(["boot", "shutdown", "restart", "delete"])
})
export type SimulatorDeviceAction = typeof SimulatorDeviceAction.Type

export const SimulatorCreateDevice = Schema.Struct({
  name: Schema.String,
  deviceTypeIdentifier: Schema.String,
  runtimeIdentifier: Schema.String
})
export type SimulatorCreateDevice = typeof SimulatorCreateDevice.Type

export const SimulatorRenameDevice = Schema.Struct({
  udid: Schema.String,
  name: Schema.String
})
export type SimulatorRenameDevice = typeof SimulatorRenameDevice.Type

export const SimulatorAppearance = Schema.Literals(["light", "dark"])
export const SimulatorContentSize = Schema.Literals([
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
export const SimulatorLocation = Schema.Literals([
  "none",
  "apple",
  "city-run",
  "city-bicycle-ride",
  "freeway-drive"
])

export const SimulatorColorFilter = Schema.Literals([
  "none",
  "protanopia",
  "deuteranopia",
  "tritanopia",
  "grayscale"
])

export const SimulatorLiquidGlass = Schema.Number.check(
  Schema.isBetween({ minimum: 0, maximum: 1 })
)

export const SimulatorAudioDevice = Schema.Struct({
  uid: Schema.String,
  name: Schema.String
})
export type SimulatorAudioDevice = typeof SimulatorAudioDevice.Type

export const SimulatorAudioRoute = Schema.String.check(Schema.isMaxLength(512))
export const SimulatorVolume = Schema.Number.check(Schema.isBetween({ minimum: 0, maximum: 100 }))

export const SimulatorSettings = Schema.Struct({
  appearance: Schema.optional(SimulatorAppearance),
  liquidGlass: Schema.optional(SimulatorLiquidGlass),
  colorFilter: Schema.optional(SimulatorColorFilter),
  contentSize: Schema.optional(SimulatorContentSize),
  increaseContrast: Schema.optional(Schema.Boolean),
  reduceMotion: Schema.optional(Schema.Boolean),
  showBorders: Schema.optional(Schema.Boolean),
  reduceTransparency: Schema.optional(Schema.Boolean),
  voiceOver: Schema.optional(Schema.Boolean),
  location: SimulatorLocation,
  volume: Schema.optional(SimulatorVolume),
  audioOutput: Schema.optional(SimulatorAudioRoute),
  audioInput: Schema.optional(SimulatorAudioRoute),
  audioOutputs: Schema.optional(Schema.Array(SimulatorAudioDevice)),
  audioInputs: Schema.optional(Schema.Array(SimulatorAudioDevice))
})
export type SimulatorSettings = typeof SimulatorSettings.Type

export const SimulatorSettingsChange = Schema.Struct({
  udid: Schema.String,
  appearance: Schema.optional(SimulatorAppearance),
  liquidGlass: Schema.optional(SimulatorLiquidGlass),
  colorFilter: Schema.optional(SimulatorColorFilter),
  contentSize: Schema.optional(SimulatorContentSize),
  increaseContrast: Schema.optional(Schema.Boolean),
  reduceMotion: Schema.optional(Schema.Boolean),
  showBorders: Schema.optional(Schema.Boolean),
  reduceTransparency: Schema.optional(Schema.Boolean),
  voiceOver: Schema.optional(Schema.Boolean),
  location: Schema.optional(SimulatorLocation),
  volume: Schema.optional(SimulatorVolume),
  audioOutput: Schema.optional(SimulatorAudioRoute),
  audioInput: Schema.optional(SimulatorAudioRoute)
})
export type SimulatorSettingsChange = typeof SimulatorSettingsChange.Type

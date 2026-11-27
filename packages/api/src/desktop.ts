import { Schema } from "effect"

export const DesktopState = Schema.Literals(["none", "running", "stopped", "outdated"])
export type DesktopState = typeof DesktopState.Type

export const DesktopSudo = Schema.Literals(["passwordless", "password", "none"])
export type DesktopSudo = typeof DesktopSudo.Type

export const OldDesktop = Schema.Struct({
  units: Schema.Array(Schema.String)
})
export type OldDesktop = typeof OldDesktop.Type

export const ScreenState = Schema.Literals(["none", "waiting", "running", "stopped"])
export type ScreenState = typeof ScreenState.Type

export const ScreenStatus = Schema.Struct({
  state: ScreenState,
  session: Schema.optional(Schema.String),
  display: Schema.optional(Schema.String),
  problem: Schema.optional(Schema.String),
  missing: Schema.Array(Schema.String),
  others: Schema.Array(Schema.String)
})
export type ScreenStatus = typeof ScreenStatus.Type

export const DesktopStatus = Schema.Struct({
  state: DesktopState,
  account: Schema.String,
  system: Schema.String,
  display: Schema.optional(Schema.Number),
  problem: Schema.optional(Schema.String),
  unmanaged: Schema.optional(Schema.Boolean),
  keepsRunning: Schema.optional(Schema.Boolean),
  unitOwnedByAnother: Schema.optional(Schema.Boolean),
  busy: Schema.optional(Schema.String),
  failure: Schema.optional(Schema.String),
  missing: Schema.Array(Schema.String),
  packageManager: Schema.optional(Schema.String),
  sudo: Schema.optional(DesktopSudo),
  oldDesktop: Schema.optional(OldDesktop),
  startsAtBoot: Schema.Boolean,
  startAtBootHint: Schema.optional(Schema.String),
  logHint: Schema.String,
  screen: Schema.optional(ScreenStatus)
})
export type DesktopStatus = typeof DesktopStatus.Type

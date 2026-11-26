import { Schema } from "effect"

export const DesktopState = Schema.Literals(["none", "running", "stopped", "outdated"])
export type DesktopState = typeof DesktopState.Type

export const DesktopSudo = Schema.Literals(["passwordless", "password", "none"])
export type DesktopSudo = typeof DesktopSudo.Type

export const DesktopCommand = Schema.Array(Schema.String)
export type DesktopCommand = typeof DesktopCommand.Type

export const OldDesktop = Schema.Struct({
  units: Schema.Array(Schema.String),
  removal: Schema.Array(DesktopCommand)
})
export type OldDesktop = typeof OldDesktop.Type

export const DesktopStatus = Schema.Struct({
  state: DesktopState,
  account: Schema.String,
  system: Schema.String,
  display: Schema.optional(Schema.Number),
  problem: Schema.optional(Schema.String),
  missing: Schema.Array(Schema.String),
  install: Schema.optional(Schema.Array(DesktopCommand)),
  sudo: DesktopSudo,
  oldDesktop: Schema.optional(OldDesktop),
  startsAtBoot: Schema.Boolean,
  startAtBootHint: Schema.optional(Schema.String),
  logHint: Schema.String
})
export type DesktopStatus = typeof DesktopStatus.Type

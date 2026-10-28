import { Schema } from "effect"

export const SessionAutoResume = Schema.Struct({
  state: Schema.optional(Schema.Literals(["scheduled", "resuming", "failed"])),
  resumesAt: Schema.optional(Schema.String)
})
export type SessionAutoResume = typeof SessionAutoResume.Type

export const SessionAutoResumeUpdate = Schema.Struct({
  state: Schema.Literals(["scheduled", "resuming", "failed", "cleared"]),
  resumesAt: Schema.optional(Schema.String)
})
export type SessionAutoResumeUpdate = typeof SessionAutoResumeUpdate.Type

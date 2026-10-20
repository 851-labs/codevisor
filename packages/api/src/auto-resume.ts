import { Schema } from "effect"

export const SessionAutoResume = Schema.Struct({
  resumesAt: Schema.optional(Schema.String)
})
export type SessionAutoResume = typeof SessionAutoResume.Type

export const SessionAutoResumeUpdate = Schema.Struct({
  state: Schema.Literals(["scheduled", "cleared"]),
  resumesAt: Schema.optional(Schema.String)
})
export type SessionAutoResumeUpdate = typeof SessionAutoResumeUpdate.Type

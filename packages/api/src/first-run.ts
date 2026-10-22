import { Schema } from "effect"

export const FirstRunHarness = Schema.Struct({
  id: Schema.String,
  name: Schema.String
})
export type FirstRunHarness = typeof FirstRunHarness.Type

export const FirstRunState = Schema.Literals(["notApplicable", "running", "done", "failed"])
export type FirstRunState = typeof FirstRunState.Type

export const FirstRunStatus = Schema.Struct({
  state: FirstRunState,
  harnesses: Schema.optional(Schema.Array(FirstRunHarness)),
  addedProjects: Schema.optional(Schema.Number)
})
export type FirstRunStatus = typeof FirstRunStatus.Type

export const FIRST_RUN_EVENT_SUBJECT = "first-run"

import { Schema } from "effect"

export const FirstRunHarness = Schema.Struct({
  id: Schema.String,
  name: Schema.String
})
export type FirstRunHarness = typeof FirstRunHarness.Type

export const FirstRunProject = Schema.Struct({
  id: Schema.String,
  name: Schema.String
})
export type FirstRunProject = typeof FirstRunProject.Type

export const FirstRunState = Schema.Literals(["notApplicable", "running", "done", "failed"])
export type FirstRunState = typeof FirstRunState.Type

export const FirstRunStatus = Schema.Struct({
  state: FirstRunState,
  harnesses: Schema.optional(Schema.Array(FirstRunHarness)),
  projects: Schema.optional(Schema.Array(FirstRunProject))
})
export type FirstRunStatus = typeof FirstRunStatus.Type

export const FIRST_RUN_EVENT_SUBJECT = "first-run"

import { Schema } from "effect"

import { Harness } from "./harnesses.js"

export const SessionOrigin = Schema.Union([
  Schema.Literal("codevisor"),
  Schema.Literal("imported"),
  Schema.Literal("herdman").transform("codevisor")
])
export type SessionOrigin = typeof SessionOrigin.Type

export const AgentSessionSummary = Schema.Struct({
  sessionId: Schema.String,
  cwd: Schema.String,
  title: Schema.optional(Schema.String),
  updatedAt: Schema.optional(Schema.String)
})
export type AgentSessionSummary = typeof AgentSessionSummary.Type

export const CanonicalModeId = Schema.Literals([
  "readOnly",
  "ask",
  "autoEdit",
  "fullAccess",
  "plan"
])
export type CanonicalModeId = typeof CanonicalModeId.Type

export const SessionMode = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  description: Schema.optional(Schema.String),
  canonicalId: Schema.optional(CanonicalModeId)
})
export type SessionMode = typeof SessionMode.Type

export const SessionModeState = Schema.Struct({
  currentModeId: Schema.String,
  availableModes: Schema.Array(SessionMode)
})
export type SessionModeState = typeof SessionModeState.Type

export const SessionConfigSelectOption = Schema.Struct({
  value: Schema.String,
  name: Schema.String,
  description: Schema.optional(Schema.String)
})
export type SessionConfigSelectOption = typeof SessionConfigSelectOption.Type

export const SessionConfigSelectGroup = Schema.Struct({
  group: Schema.String,
  name: Schema.String,
  options: Schema.Array(SessionConfigSelectOption)
})
export type SessionConfigSelectGroup = typeof SessionConfigSelectGroup.Type

export const SessionConfigOption = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  description: Schema.optional(Schema.String),
  category: Schema.optional(Schema.String),
  currentValue: Schema.String,
  options: Schema.Union([
    Schema.Array(SessionConfigSelectOption),
    Schema.Array(SessionConfigSelectGroup)
  ])
})
export type SessionConfigOption = typeof SessionConfigOption.Type

export const GoalStatus = Schema.Literals([
  "active",
  "paused",
  "blocked",
  "usageLimited",
  "budgetLimited",
  "complete"
])
export type GoalStatus = typeof GoalStatus.Type

export const GoalActivity = Schema.Literals(["planning", "verifying"])
export type GoalActivity = typeof GoalActivity.Type

export const SessionGoal = Schema.Struct({
  objective: Schema.String,
  status: GoalStatus,
  activity: Schema.optional(GoalActivity),
  tokenBudget: Schema.NullOr(Schema.Number),
  tokensUsed: Schema.Number,
  timeUsedSeconds: Schema.Number,
  createdAt: Schema.String,
  updatedAt: Schema.String
})
export type SessionGoal = typeof SessionGoal.Type

export const SessionSkillSource = Schema.Literals([
  "builtin",
  "project",
  "user",
  "plugin",
  "codevisor"
])
export type SessionSkillSource = typeof SessionSkillSource.Type

export const SessionSkill = Schema.Struct({
  name: Schema.String,
  description: Schema.optional(Schema.String),
  invocation: Schema.String,
  source: Schema.optional(SessionSkillSource)
})
export type SessionSkill = typeof SessionSkill.Type

export const SessionSkills = Schema.Struct({
  skills: Schema.Array(SessionSkill),
  invocationPrefix: Schema.String,
  commands: Schema.optional(Schema.Array(Schema.String))
})
export type SessionSkills = typeof SessionSkills.Type

export const HarnessCapability = Schema.Struct({
  harness: Harness,
  modes: Schema.optional(SessionModeState),
  configOptions: Schema.Array(SessionConfigOption),
  supportsGoals: Schema.optional(Schema.Boolean),
  supportsSteering: Schema.optional(Schema.Boolean),
  skills: Schema.optional(SessionSkills),
  unappliedConfigSelections: Schema.optional(Schema.Record(Schema.String, Schema.String))
})
export type HarnessCapability = typeof HarnessCapability.Type

export const ServerCapabilities = Schema.Struct({
  harnesses: Schema.Array(HarnessCapability)
})
export type ServerCapabilities = typeof ServerCapabilities.Type

export const SetModeRequest = Schema.Struct({
  modeId: Schema.String,
  clientActionId: Schema.optional(Schema.String)
})
export type SetModeRequest = typeof SetModeRequest.Type

export const SetConfigRequest = Schema.Struct({
  configId: Schema.String,
  value: Schema.String,
  clientActionId: Schema.optional(Schema.String)
})
export type SetConfigRequest = typeof SetConfigRequest.Type

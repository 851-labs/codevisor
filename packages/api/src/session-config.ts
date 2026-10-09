import { Schema } from "effect"

import { Harness } from "./harnesses.js"

export const SessionOrigin = Schema.Union([
  Schema.Literal("codevisor"),
  Schema.Literal("imported"),
  // Decode payloads from pre-rename servers without leaking the former value
  // into the current application model.
  Schema.Literal("herdman").transform("codevisor")
])
export type SessionOrigin = typeof SessionOrigin.Type

/// A session from a harness's own on-disk store (run before/outside
/// Codevisor) — the source for onboarding's workspace suggestions and
/// "import existing chats".
export const AgentSessionSummary = Schema.Struct({
  sessionId: Schema.String,
  cwd: Schema.String,
  title: Schema.optional(Schema.String),
  updatedAt: Schema.optional(Schema.String)
})
export type AgentSessionSummary = typeof AgentSessionSummary.Type

/// Codevisor's harness-independent mode vocabulary. Providers map their native
/// permission/approval modes onto these ids so the client can render one
/// consistent picker; modes without a mapping stay native-only.
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

/// Lifecycle of a session goal, mirroring codex's thread-goal statuses.
/// `active` goals auto-continue turns agent-side until done or limited.
export const GoalStatus = Schema.Literals([
  "active",
  "paused",
  "blocked",
  "usageLimited",
  "budgetLimited",
  "complete"
])
export type GoalStatus = typeof GoalStatus.Type

/// Transient work happening inside an active goal. Unlike the lifecycle
/// status, this may appear and disappear many times before the goal resolves.
export const GoalActivity = Schema.Literals(["planning", "verifying"])
export type GoalActivity = typeof GoalActivity.Type

/// A persistent per-session objective (codex "goal mode"). Snapshots are
/// idempotent full state: consumers replace, never accumulate.
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

/// Where a composer skill comes from: shipped with the harness (`builtin`),
/// the workspace's or the user's skill folders (`project`, `user`), a harness
/// plugin (`plugin`), or Codevisor's own skill store (`codevisor`).
export const SessionSkillSource = Schema.Literals([
  "builtin",
  "project",
  "user",
  "plugin",
  "codevisor"
])
export type SessionSkillSource = typeof SessionSkillSource.Type

/// One skill the user can invoke from the composer. Harness commands that
/// are not skills (`/compact`, `/model`, …) are never listed.
export const SessionSkill = Schema.Struct({
  name: Schema.String,
  description: Schema.optional(Schema.String),
  /// The exact text that invokes the skill in this harness's prompt:
  /// "/review" (Claude, OpenCode, Cursor, Grok), "$review" (Codex), or
  /// "/skill:review" (Pi).
  invocation: Schema.String,
  source: Schema.optional(SessionSkillSource)
})
export type SessionSkill = typeof SessionSkill.Type

/// The skills a harness session can invoke, as one replaceable snapshot. It
/// rides on harness capabilities (for chats that have not started their
/// harness yet) and as the `available_skills_update` session update.
export const SessionSkills = Schema.Struct({
  skills: Schema.Array(SessionSkill),
  /// The prefix that invokes a skill the harness does not know natively
  /// (Codevisor store skills): "$" for Codex, "/" elsewhere.
  invocationPrefix: Schema.String
})
export type SessionSkills = typeof SessionSkills.Type

export const HarnessCapability = Schema.Struct({
  harness: Harness,
  modes: Schema.optional(SessionModeState),
  configOptions: Schema.Array(SessionConfigOption),
  supportsGoals: Schema.optional(Schema.Boolean),
  /// Skills a fresh session in the inspected directory can invoke. Absent
  /// when the harness cannot list them.
  skills: Schema.optional(SessionSkills),
  /// Requested selections (config id → requested value) the inspection could
  /// not apply: the harness does not offer the value (even after reconciling
  /// a drifted id onto its current entry) or rejected it. A value that was
  /// reconciled onto a different id is applied, not listed here — the
  /// option's `currentValue` carries the reconciled id.
  unappliedConfigSelections: Schema.optional(Schema.Record(Schema.String, Schema.String))
})
export type HarnessCapability = typeof HarnessCapability.Type

export const ServerCapabilities = Schema.Struct({
  harnesses: Schema.Array(HarnessCapability)
})
export type ServerCapabilities = typeof ServerCapabilities.Type

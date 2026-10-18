import { Schema } from "effect"

export const EventKind = Schema.Literals([
  "navigation.changed",
  "project.created",
  "project.updated",
  "project.deleted",
  "project.setup",
  "worktree.created",
  "worktree.setup",
  "workspace.updated",
  "workspace.deleted",
  "workspace.pane.updated",
  "workspace.pane.deleted",
  "session.created",
  "session.updated",
  "session.attention.updated",
  "session.archived",
  "session.unarchived",
  "session.deleted",
  "session.output",
  "session.queue.updated",
  "session.error",
  "session.authRequired",
  "harness.auth.updated",
  "harness.account.updated",
  "harness.authFlow.updated",
  "harness.lifecycle.updated",
  "session.updateGate.updated",
  "plugin.state.updated",
  "plugin.updated",
  "terminal.output",
  "terminal.exit",
  "update.changed",
  "mcp.updated",
  "bot.updated",
  "bot.message",
  "sync.changed"
])
export type EventKind = typeof EventKind.Type

export const EventEnvelope = Schema.Struct({
  id: Schema.Number,
  globalEventId: Schema.optional(Schema.Number),
  subjectRevision: Schema.optional(Schema.Number),
  serverId: Schema.String,
  kind: EventKind,
  subjectId: Schema.String,
  createdAt: Schema.String,
  payload: Schema.Unknown
})
export type EventEnvelope = typeof EventEnvelope.Type

export const EventCursorResponse = Schema.Struct({
  cursor: Schema.Number
})
export type EventCursorResponse = typeof EventCursorResponse.Type

export const DataUpgradeProgress = Schema.Struct({
  state: Schema.Literals(["running", "completed", "failed"]),
  id: Schema.String,
  name: Schema.String,
  completed: Schema.Number,
  total: Schema.Number,
  error: Schema.optional(Schema.String)
})
export type DataUpgradeProgress = typeof DataUpgradeProgress.Type

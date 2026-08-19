import { Schema } from "effect"

export const EventKind = Schema.Literals([
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
  /// Emitted when a chat leaves the archive. Distinct from `session.updated`
  /// because clients must move the row between sidebar sections and may need
  /// to re-resolve its cwd: restore can hand back a different worktree name
  /// when the original was reclaimed while the chat sat archived.
  "session.unarchived",
  "session.deleted",
  "session.output",
  "session.queue.updated",
  "session.error",
  "session.authRequired",
  "harness.auth.updated",
  "harness.account.updated",
  "harness.authFlow.updated",
  /// Install/update lifecycle for one harness (subjectId = harness id).
  /// Payload: { harnessId, lifecycle: HarnessLifecycleState, updateInfo? }.
  "harness.lifecycle.updated",
  /// A session's prompts are held while its harness updates (subjectId =
  /// session id). Payload: { state: "waiting" | "released", harnessId,
  /// harnessName }. Replaceable: the latest event wins.
  "session.updateGate.updated",
  "terminal.output",
  "terminal.exit",
  "update.changed"
])
export type EventKind = typeof EventKind.Type

export const EventEnvelope = Schema.Struct({
  id: Schema.Number,
  /// Global shell-log cursor when this event also changes project/session
  /// metadata. Chat-only events intentionally omit it.
  globalEventId: Schema.optional(Schema.Number),
  /// Monotonic sequence within `subjectId`. Session-scoped streams use this
  /// cursor so an unrelated project/session event can never invalidate a
  /// chat's resume position.
  subjectRevision: Schema.optional(Schema.Number),
  serverId: Schema.String,
  kind: EventKind,
  subjectId: Schema.String,
  createdAt: Schema.String,
  payload: Schema.Unknown
})
export type EventEnvelope = typeof EventEnvelope.Type

/** Durable cursor for the global shell event log. Capture this before a
 * navigation snapshot, then replay events after it to close the snapshot-to-
 * stream race without replaying the entire log. */
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

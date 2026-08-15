import { Schema } from "effect"

/// A pane workspace: the server-owned identity of one working surface inside
/// a project. It names the surface, points at the directory it works in (a
/// worktree path or the project folder), and owns sessions. Pane layout
/// (split trees) deliberately stays client-side.
export const Workspace = Schema.Struct({
  id: Schema.String,
  serverId: Schema.String,
  projectId: Schema.String,
  name: Schema.String,
  hasCustomName: Schema.Boolean,
  symbolName: Schema.optional(Schema.String),
  rootDirectory: Schema.optional(Schema.String),
  isArchived: Schema.Boolean,
  archivedAt: Schema.optional(Schema.String),
  createdAt: Schema.String,
  updatedAt: Schema.optional(Schema.String)
})
export type Workspace = typeof Workspace.Type

/// Partial workspace update. Exists alongside the full `PUT` upsert so a client
/// can archive a workspace without resending (and racing on) its whole record.
export const UpdateWorkspaceRequest = Schema.Struct({
  name: Schema.optional(Schema.String),
  hasCustomName: Schema.optional(Schema.Boolean),
  symbolName: Schema.optional(Schema.String),
  rootDirectory: Schema.optional(Schema.String),
  /// Archiving a workspace cascades to its sessions while retaining pane
  /// layout; unarchiving revives only the sessions that cascade archived.
  isArchived: Schema.optional(Schema.Boolean)
})
export type UpdateWorkspaceRequest = typeof UpdateWorkspaceRequest.Type

export const UpsertWorkspaceRequest = Schema.Struct({
  /// Optional because the route path carries the id; when both are present
  /// they must match.
  id: Schema.optional(Schema.String),
  projectId: Schema.String,
  name: Schema.String,
  hasCustomName: Schema.Boolean,
  symbolName: Schema.optional(Schema.String),
  rootDirectory: Schema.optional(Schema.String),
  isArchived: Schema.optional(Schema.Boolean),
  /// Client backfills preserve the original creation date.
  createdAt: Schema.optional(Schema.String)
})
export type UpsertWorkspaceRequest = typeof UpsertWorkspaceRequest.Type

export const Worktree = Schema.Struct({
  id: Schema.String,
  projectId: Schema.String,
  serverId: Schema.String,
  name: Schema.String,
  branch: Schema.String,
  path: Schema.String,
  createdAt: Schema.String
})
export type Worktree = typeof Worktree.Type

/// A worktree whose files have been removed, with its contents preserved as a
/// git snapshot commit under `refs/codevisor/archived/<id>`. Deliberately a
/// separate record from `Worktree`: archiving deletes the `worktrees` row so
/// the (finite, ~500-name) food name pool is freed immediately, so restore is
/// keyed by id and treats `originalName` only as the name it prefers to
/// reclaim. `parentSha` is the commit the snapshot was taken against — the
/// restore target when the original branch has moved or been deleted.
export const ArchivedWorktree = Schema.Struct({
  id: Schema.String,
  projectId: Schema.String,
  serverId: Schema.String,
  originalName: Schema.String,
  branch: Schema.String,
  parentSha: Schema.String,
  snapshotRef: Schema.String,
  createdAt: Schema.String
})
export type ArchivedWorktree = typeof ArchivedWorktree.Type

export const CreateWorktreeRequest = Schema.Struct({
  /// Client-supplied worktree id so callers can follow `worktree.setup` events
  /// (subjectId = worktree id) while the create request is still in flight.
  id: Schema.optional(Schema.String),
  /// Optional Codevisor session id that should also receive mirrored
  /// `worktree.setup` progress while the session is waiting for first setup.
  sessionId: Schema.optional(Schema.String),
  name: Schema.optional(Schema.String)
})
export type CreateWorktreeRequest = typeof CreateWorktreeRequest.Type

export const WorktreeSetupState = Schema.Literals(["started", "log", "completed", "failed"])
export type WorktreeSetupState = typeof WorktreeSetupState.Type

/** Progress payload carried on `worktree.setup` envelopes while the server
 *  materializes a worktree (`git worktree add` plus any checkout hooks).
 *  `log` updates stream one output line each; `completed`/`failed` carry the
 *  total `durationMs`, and `failed` carries the error `message`. */
export const WorktreeSetupUpdate = Schema.Struct({
  state: WorktreeSetupState,
  worktreeId: Schema.String,
  projectId: Schema.String,
  name: Schema.String,
  branch: Schema.String,
  stream: Schema.optional(Schema.Literals(["stdout", "stderr"])),
  line: Schema.optional(Schema.String),
  message: Schema.optional(Schema.String),
  durationMs: Schema.optional(Schema.Number)
})
export type WorktreeSetupUpdate = typeof WorktreeSetupUpdate.Type

import { Schema } from "effect"

import { WorkspaceGit } from "./git-review.js"
import { Labels } from "./labels.js"
import { CreateSessionRequest, SessionSummary } from "./sessions.js"
import { WorkspacePosition } from "./workspace-position.js"

export const Workspace = Schema.Struct({
  id: Schema.String,
  serverId: Schema.String,
  projectId: Schema.String,
  name: Schema.String,
  hasCustomName: Schema.Boolean,
  rootDirectory: Schema.optional(Schema.String),
  isArchived: Schema.Boolean,
  archivedAt: Schema.optional(Schema.String),
  createdAt: Schema.String,
  updatedAt: Schema.optional(Schema.String),
  sidebarPosition: Schema.optional(WorkspacePosition),
  sidebarOrderRevision: Schema.optional(Schema.Number),
  labels: Schema.optional(Labels),
  git: Schema.optional(WorkspaceGit),
  botId: Schema.optional(Schema.String)
})
export type Workspace = typeof Workspace.Type

export const UpdateWorkspaceRequest = Schema.Struct({
  sidebarOrder: Schema.optional(
    Schema.Struct({
      position: WorkspacePosition,
      expectedRevision: Schema.optional(Schema.Number)
    })
  ),
  name: Schema.optional(Schema.String),
  hasCustomName: Schema.optional(Schema.Boolean),
  rootDirectory: Schema.optional(Schema.String),
  isArchived: Schema.optional(Schema.Boolean),
  labels: Schema.optional(Labels)
})
export type UpdateWorkspaceRequest = typeof UpdateWorkspaceRequest.Type

export const UpsertWorkspaceRequest = Schema.Struct({
  sidebarOrderHead: Schema.optional(WorkspacePosition),
  sidebarPosition: Schema.optional(WorkspacePosition),
  id: Schema.optional(Schema.String),
  projectId: Schema.String,
  name: Schema.String,
  hasCustomName: Schema.Boolean,
  rootDirectory: Schema.optional(Schema.String),
  isArchived: Schema.optional(Schema.Boolean),
  createdAt: Schema.optional(Schema.String),
  labels: Schema.optional(Labels)
})
export type UpsertWorkspaceRequest = typeof UpsertWorkspaceRequest.Type

export const TerminalActivity = Schema.Literals(["working", "idle", "done", "blocked", "error"])
export type TerminalActivity = typeof TerminalActivity.Type

export const WorkspacePane = Schema.Struct({
  id: Schema.String,
  workspaceId: Schema.String,
  providerId: Schema.String,
  paneType: Schema.String,
  title: Schema.String,
  resourceKind: Schema.optional(Schema.String),
  resourceId: Schema.optional(Schema.String),
  metadata: Schema.optional(Schema.String),
  liveTitle: Schema.optional(Schema.String),
  terminalActivity: Schema.optional(TerminalActivity),
  revision: Schema.Number,
  position: Schema.optional(Schema.String),
  createdAt: Schema.String,
  updatedAt: Schema.optional(Schema.String)
})
export type WorkspacePane = typeof WorkspacePane.Type

export const WorkspaceSnapshot = Schema.Struct({
  workspaces: Schema.Array(Workspace),
  panes: Schema.Array(WorkspacePane)
})
export type WorkspaceSnapshot = typeof WorkspaceSnapshot.Type

export const CloseWorkspacePaneResponse = Schema.Struct({
  pane: Schema.optional(WorkspacePane)
})
export type CloseWorkspacePaneResponse = typeof CloseWorkspacePaneResponse.Type

export const UpsertWorkspacePaneRequest = Schema.Struct({
  id: Schema.optional(Schema.String),
  providerId: Schema.String,
  paneType: Schema.String,
  title: Schema.String,
  resourceKind: Schema.optional(Schema.String),
  resourceId: Schema.optional(Schema.String),
  metadata: Schema.optional(Schema.String),
  createdAt: Schema.optional(Schema.String)
})
export type UpsertWorkspacePaneRequest = typeof UpsertWorkspacePaneRequest.Type

export const UpdateWorkspacePaneRequest = Schema.Struct({
  providerId: Schema.optional(Schema.String),
  paneType: Schema.optional(Schema.String),
  title: Schema.optional(Schema.String),
  resourceKind: Schema.optional(Schema.NullOr(Schema.String)),
  resourceId: Schema.optional(Schema.NullOr(Schema.String)),
  metadata: Schema.optional(Schema.NullOr(Schema.String)),
  position: Schema.optional(WorkspacePosition)
})
export type UpdateWorkspacePaneRequest = typeof UpdateWorkspacePaneRequest.Type

export const ReorderWorkspacePanesRequest = Schema.Struct({
  paneIds: Schema.Array(Schema.String)
})
export type ReorderWorkspacePanesRequest = typeof ReorderWorkspacePanesRequest.Type

export const PromoteWorkspacePaneToChatRequest = Schema.Struct({
  session: CreateSessionRequest,
  title: Schema.optional(Schema.String)
})
export type PromoteWorkspacePaneToChatRequest = typeof PromoteWorkspacePaneToChatRequest.Type

export const PromoteWorkspacePaneToChatResponse = Schema.Struct({
  pane: WorkspacePane,
  session: SessionSummary
})
export type PromoteWorkspacePaneToChatResponse = typeof PromoteWorkspacePaneToChatResponse.Type

export const CreateWorkspaceRequest = Schema.Struct({
  workspace: UpsertWorkspaceRequest,
  session: CreateSessionRequest,
  pane: Schema.optional(
    Schema.Struct({
      id: Schema.optional(Schema.String),
      title: Schema.optional(Schema.String)
    })
  )
})
export type CreateWorkspaceRequest = typeof CreateWorkspaceRequest.Type

export const CreateWorkspaceResponse = Schema.Struct({
  workspace: Workspace,
  session: SessionSummary,
  pane: WorkspacePane
})
export type CreateWorkspaceResponse = typeof CreateWorkspaceResponse.Type

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

export const ArchivedWorktreeState = Schema.Literals(["pending", "complete"])
export type ArchivedWorktreeState = typeof ArchivedWorktreeState.Type

export const ArchivedWorktree = Schema.Struct({
  id: Schema.String,
  projectId: Schema.String,
  serverId: Schema.String,
  originalName: Schema.String,
  branch: Schema.String,
  parentSha: Schema.String,
  snapshotRef: Schema.String,
  createdAt: Schema.String,
  state: ArchivedWorktreeState
})
export type ArchivedWorktree = typeof ArchivedWorktree.Type

export const CreateWorktreeRequest = Schema.Struct({
  id: Schema.optional(Schema.String),
  sessionId: Schema.optional(Schema.String),
  name: Schema.optional(Schema.String)
})
export type CreateWorktreeRequest = typeof CreateWorktreeRequest.Type

export const WorktreeSetupState = Schema.Literals(["started", "log", "completed", "failed"])
export type WorktreeSetupState = typeof WorktreeSetupState.Type

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

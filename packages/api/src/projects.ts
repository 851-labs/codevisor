import { Schema } from "effect"
import { SessionOrigin } from "./session-config.js"

export const ProjectLocation = Schema.Struct({
  id: Schema.String,
  projectId: Schema.String,
  serverId: Schema.String,
  folderPath: Schema.String,
  createdAt: Schema.String,
  isGitRepository: Schema.optional(Schema.Boolean)
})
export type ProjectLocation = typeof ProjectLocation.Type

/// The remote-tracking branch new Codevisor worktrees start from. Keeping the
/// remote separate from the branch avoids baking an `origin` assumption into
/// project configuration and preserves branch names containing slashes.
export const ProjectWorktreeBase = Schema.Struct({
  remote: Schema.String,
  branch: Schema.String
})
export type ProjectWorktreeBase = typeof ProjectWorktreeBase.Type

/// One remote branch offered by the project settings branch picker.
export const ProjectGitBranch = Schema.Struct({
  remote: Schema.String,
  branch: Schema.String,
  isDefault: Schema.Boolean
})
export type ProjectGitBranch = typeof ProjectGitBranch.Type

export const Project = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  isArchived: Schema.Boolean,
  /// When the row was archived. `isArchived` is the derived mirror kept for
  /// clients predating the archived-sections release; new UI should sort and
  /// label from this timestamp.
  archivedAt: Schema.optional(Schema.String),
  origin: SessionOrigin,
  createdAt: Schema.String,
  locations: Schema.Array(ProjectLocation),
  /// The git remote this project was cloned from (projects added via
  /// /v1/projects/from-git). Machine-independent by design: any machine can
  /// materialize the same project by cloning the same remote.
  repoUrl: Schema.optional(Schema.String),
  /// An explicit base for newly-created worktrees. Absent preserves the
  /// legacy origin/main (then HEAD) behavior for existing projects.
  worktreeBase: Schema.optional(ProjectWorktreeBase),
  /// True for the hidden backing project of a scratch workspace (its folder
  /// lives under ~/codevisor/workspaces). Derived from the folder location by
  /// the server on every response, never stored, so clients can filter these
  /// out of project pickers without a schema migration.
  isScratch: Schema.optional(Schema.Boolean)
})
export type Project = typeof Project.Type

export const CreateProjectRequest = Schema.Struct({
  id: Schema.optional(Schema.String),
  folderPath: Schema.String,
  name: Schema.optional(Schema.String),
  isArchived: Schema.optional(Schema.Boolean),
  origin: Schema.optional(SessionOrigin),
  createdAt: Schema.optional(Schema.String),
  repoUrl: Schema.optional(Schema.String)
})
export type CreateProjectRequest = typeof CreateProjectRequest.Type

/// Create the hidden backing project for a brand-new scratch workspace: the
/// server allocates a memorable name, creates an empty folder for it under
/// ~/codevisor/workspaces, and registers a project pointing at that folder.
export const CreateScratchProjectRequest = Schema.Struct({
  /// Client-supplied project id so creation is idempotent per workspace.
  id: Schema.optional(Schema.String)
})
export type CreateScratchProjectRequest = typeof CreateScratchProjectRequest.Type

/// Clone a git remote into the machine's managed repos directory and register
/// the checkout as a project. The client-supplied id lets callers follow the
/// clone's project.setup progress events while the request is in flight (the
/// same trick as CreateWorktreeRequest.id).
export const CreateProjectFromGitRequest = Schema.Struct({
  id: Schema.optional(Schema.String),
  url: Schema.String,
  name: Schema.optional(Schema.String)
})
export type CreateProjectFromGitRequest = typeof CreateProjectFromGitRequest.Type

export const ProjectSetupState = Schema.Literals(["started", "log", "completed", "failed"])
export type ProjectSetupState = typeof ProjectSetupState.Type

/// Machine-readable failure category for clone errors, so clients can show
/// actionable guidance instead of raw git stderr.
export const ProjectSetupErrorCode = Schema.Literals([
  "auth_failed",
  "repo_not_found",
  "network",
  "disk_full",
  "invalid_url",
  "already_exists"
])
export type ProjectSetupErrorCode = typeof ProjectSetupErrorCode.Type

export const ProjectSetupUpdate = Schema.Struct({
  state: ProjectSetupState,
  projectId: Schema.String,
  url: Schema.String,
  stream: Schema.optional(Schema.Literals(["stdout", "stderr"])),
  line: Schema.optional(Schema.String),
  message: Schema.optional(Schema.String),
  code: Schema.optional(ProjectSetupErrorCode),
  durationMs: Schema.optional(Schema.Number)
})
export type ProjectSetupUpdate = typeof ProjectSetupUpdate.Type

export const FsEntry = Schema.Struct({
  name: Schema.String,
  path: Schema.String,
  isGitRepo: Schema.Boolean
})
export type FsEntry = typeof FsEntry.Type

/// A directory listing for the remote project picker: directories only, with
/// a git badge so repos stand out.
export const FsListResponse = Schema.Struct({
  path: Schema.String,
  parent: Schema.NullOr(Schema.String),
  entries: Schema.Array(FsEntry)
})
export type FsListResponse = typeof FsListResponse.Type

export const UpdateProjectRequest = Schema.Struct({
  name: Schema.optional(Schema.String),
  /// Archiving a project cascades to its workspaces and sessions; unarchiving
  /// revives only the children that same cascade archived. See
  /// `archive_cascade_from` in @codevisor/db.
  isArchived: Schema.optional(Schema.Boolean),
  /// Null clears an explicit selection and restores the legacy default.
  worktreeBase: Schema.optional(Schema.NullOr(ProjectWorktreeBase))
})
export type UpdateProjectRequest = typeof UpdateProjectRequest.Type

/// A pane workspace: the server-owned identity of one working surface inside
/// a project. It names the surface, points at the directory it works in (a
/// worktree path or the project folder), and owns sessions. Pane layout

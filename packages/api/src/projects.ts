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

export const ProjectWorktreeBase = Schema.Struct({
  remote: Schema.String,
  branch: Schema.String
})
export type ProjectWorktreeBase = typeof ProjectWorktreeBase.Type

export const ProjectRunLocation = Schema.Literals(["projectDirectory", "newWorktree"])
export type ProjectRunLocation = typeof ProjectRunLocation.Type

export const ProjectGitBranch = Schema.Struct({
  remote: Schema.String,
  branch: Schema.String,
  isDefault: Schema.Boolean
})
export type ProjectGitBranch = typeof ProjectGitBranch.Type

export const Project = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  origin: SessionOrigin,
  createdAt: Schema.String,
  locations: Schema.Array(ProjectLocation),
  repoUrl: Schema.optional(Schema.String),
  repoKey: Schema.optional(Schema.String),
  worktreeBase: Schema.optional(ProjectWorktreeBase),
  defaultRunLocation: Schema.optional(ProjectRunLocation),
  isScratch: Schema.optional(Schema.Boolean),
  isBot: Schema.optional(Schema.Boolean)
})
export type Project = typeof Project.Type

export const ProjectRecommendation = Schema.Struct({
  path: Schema.String,
  name: Schema.String,
  sessionCount: Schema.Number,
  lastActivity: Schema.optional(Schema.String)
})
export type ProjectRecommendation = typeof ProjectRecommendation.Type

export const CreateProjectRequest = Schema.Struct({
  id: Schema.optional(Schema.String),
  folderPath: Schema.String,
  name: Schema.optional(Schema.String),
  origin: Schema.optional(SessionOrigin),
  createdAt: Schema.optional(Schema.String),
  repoUrl: Schema.optional(Schema.String)
})
export type CreateProjectRequest = typeof CreateProjectRequest.Type

export const CreateScratchProjectRequest = Schema.Struct({
  id: Schema.optional(Schema.String)
})
export type CreateScratchProjectRequest = typeof CreateScratchProjectRequest.Type

export const CreateProjectFromGitRequest = Schema.Struct({
  id: Schema.optional(Schema.String),
  url: Schema.String,
  name: Schema.optional(Schema.String)
})
export type CreateProjectFromGitRequest = typeof CreateProjectFromGitRequest.Type

export const ProjectSetupState = Schema.Literals(["started", "log", "completed", "failed"])
export type ProjectSetupState = typeof ProjectSetupState.Type

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

export const FsListResponse = Schema.Struct({
  path: Schema.String,
  parent: Schema.NullOr(Schema.String),
  entries: Schema.Array(FsEntry)
})
export type FsListResponse = typeof FsListResponse.Type

export const FsMkdirRequest = Schema.Struct({
  path: Schema.String
})
export type FsMkdirRequest = typeof FsMkdirRequest.Type

export const FsMkdirResponse = Schema.Struct({
  path: Schema.String
})
export type FsMkdirResponse = typeof FsMkdirResponse.Type

export const UpdateProjectRequest = Schema.Struct({
  name: Schema.optional(Schema.String),
  worktreeBase: Schema.optional(Schema.NullOr(ProjectWorktreeBase)),
  defaultRunLocation: Schema.optional(Schema.NullOr(ProjectRunLocation))
})
export type UpdateProjectRequest = typeof UpdateProjectRequest.Type

export const repoIdentityKey = (rawUrl: string): string | undefined => {
  const url = rawUrl.trim()
  if (url.length === 0) return undefined
  let host: string
  let path: string
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(url)) {
    let parsed: URL
    try {
      parsed = new URL(url)
    } catch {
      return undefined
    }
    host = parsed.hostname
    path = decodeURIComponent(parsed.pathname)
  } else {
    const scp = /^(?:[^@/\s]+@)?([^:/\s]+):(?!\/\/)(.+)$/.exec(url)
    if (scp === null) return undefined
    host = scp[1]!
    path = scp[2]!
  }
  host = host.toLowerCase().replace(/^\[|\]$/g, "")
  path = path
    .replace(/\\/g, "/")
    .replace(/\/+$/, "")
    .replace(/\.git$/i, "")
    .replace(/^\/+/, "")
    .replace(/^~\/?/, "")
    .toLowerCase()
  if (host.length === 0 || path.length === 0) return undefined
  return `${host}/${path}`
}

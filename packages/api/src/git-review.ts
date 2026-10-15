import { Schema } from "effect"

export const GitDiffMode = Schema.Literals([
  "uncommitted",
  "unstaged",
  "staged",
  "branch",
  "lastTurn"
])
export type GitDiffMode = typeof GitDiffMode.Type

export const GitDiffFile = Schema.Struct({
  path: Schema.String,
  oldPath: Schema.optional(Schema.String),
  status: Schema.Literals(["added", "modified", "deleted", "renamed"]),
  fingerprint: Schema.String,
  oldText: Schema.NullOr(Schema.String),
  newText: Schema.NullOr(Schema.String),
  omitted: Schema.optional(Schema.Literals(["binary", "tooLarge"]))
})
export type GitDiffFile = typeof GitDiffFile.Type

export const GitDiff = Schema.Struct({
  mode: GitDiffMode,
  repositoryRoot: Schema.String,
  base: Schema.optional(Schema.String),
  files: Schema.Array(GitDiffFile),
  truncated: Schema.Boolean,
  revision: Schema.String,
  unchanged: Schema.optional(Schema.Boolean)
})
export type GitDiff = typeof GitDiff.Type

export const GitRefBranch = Schema.Struct({
  name: Schema.String,
  remote: Schema.Boolean
})
export type GitRefBranch = typeof GitRefBranch.Type

export const GitRefs = Schema.Struct({
  currentBranch: Schema.NullOr(Schema.String),
  defaultBase: Schema.NullOr(Schema.String),
  branches: Schema.Array(GitRefBranch)
})
export type GitRefs = typeof GitRefs.Type

export const GitPullRequestState = Schema.Literals(["open", "closed", "merged"])
export type GitPullRequestState = typeof GitPullRequestState.Type

export const GitPullRequestChecks = Schema.Literals(["passing", "failing", "pending", "none"])
export type GitPullRequestChecks = typeof GitPullRequestChecks.Type

export const GitPullRequest = Schema.Struct({
  number: Schema.Number,
  title: Schema.String,
  state: GitPullRequestState,
  isDraft: Schema.Boolean,
  url: Schema.String,
  checks: GitPullRequestChecks
})
export type GitPullRequest = typeof GitPullRequest.Type

export const GitPullRequestLookup = Schema.Struct({
  pullRequest: Schema.NullOr(GitPullRequest)
})
export type GitPullRequestLookup = typeof GitPullRequestLookup.Type

export const WorkspaceGitBranch = Schema.Struct({
  branch: Schema.NullOr(Schema.String)
})
export type WorkspaceGitBranch = typeof WorkspaceGitBranch.Type

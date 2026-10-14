import { Schema } from "effect"

/// Which two trees a review compares. Every mode ends at the working tree
/// except `staged`, which compares HEAD with the index.
/// - `uncommitted`: HEAD → working tree (staged and unstaged together)
/// - `unstaged`: index → working tree
/// - `staged`: HEAD → index
/// - `branch`: merge-base with a base branch → working tree
/// - `lastTurn`: the working tree when the latest agent turn started → now
export const GitDiffMode = Schema.Literals([
  "uncommitted",
  "unstaged",
  "staged",
  "branch",
  "lastTurn"
])
export type GitDiffMode = typeof GitDiffMode.Type

/// One changed file. Both texts are sent whole so the client can lay out the
/// diff (and expand context) without another round trip.
export const GitDiffFile = Schema.Struct({
  /// Repository-relative. The new path, or the old one for a deletion.
  path: Schema.String,
  /// Set for renames only.
  oldPath: Schema.optional(Schema.String),
  status: Schema.Literals(["added", "modified", "deleted", "renamed"]),
  /// Identifies exactly this change (both sides' blob ids). Clients key
  /// per-file review state, like "viewed", on it so the state lapses when
  /// the file changes again.
  fingerprint: Schema.String,
  /// Null when that side does not exist or its content was omitted.
  oldText: Schema.NullOr(Schema.String),
  newText: Schema.NullOr(Schema.String),
  /// Why both texts are null for a file that exists on both sides.
  omitted: Schema.optional(Schema.Literals(["binary", "tooLarge"]))
})
export type GitDiffFile = typeof GitDiffFile.Type

export const GitDiff = Schema.Struct({
  mode: GitDiffMode,
  /// Absolute path of the repository's top level; file paths are relative to it.
  repositoryRoot: Schema.String,
  /// Branch mode only: the base ref actually compared against (e.g. `origin/main`).
  base: Schema.optional(Schema.String),
  files: Schema.Array(GitDiffFile),
  /// True when more files changed than one response carries.
  truncated: Schema.Boolean,
  /// Identifies exactly what was compared (both trees are content-addressed),
  /// so a client polling for changes can send it back as `revision`.
  revision: Schema.String,
  /// Set when the request's `revision` still matches: nothing changed, and
  /// `files` is empty rather than resent.
  unchanged: Schema.optional(Schema.Boolean)
})
export type GitDiff = typeof GitDiff.Type

export const GitRefBranch = Schema.Struct({
  /// Short name: `main` for a local branch, `origin/main` for a remote one.
  name: Schema.String,
  remote: Schema.Boolean
})
export type GitRefBranch = typeof GitRefBranch.Type

/// What a branch-mode base picker offers. Read from local refs only — never
/// fetched — so it stays fast and works offline.
export const GitRefs = Schema.Struct({
  /// Null when HEAD is detached.
  currentBranch: Schema.NullOr(Schema.String),
  /// The base branch mode uses when none is chosen.
  defaultBase: Schema.NullOr(Schema.String),
  /// Local branches first, then remote-tracking ones, each alphabetical.
  branches: Schema.Array(GitRefBranch)
})
export type GitRefs = typeof GitRefs.Type

export const GitPullRequestState = Schema.Literals(["open", "closed", "merged"])
export type GitPullRequestState = typeof GitPullRequestState.Type

/// The pull request's checks, rolled up: any failure wins, then anything
/// still running; `none` when it has no checks at all.
export const GitPullRequestChecks = Schema.Literals(["passing", "failing", "pending", "none"])
export type GitPullRequestChecks = typeof GitPullRequestChecks.Type

/// The pull request for a branch on the repository's GitHub remote.
export const GitPullRequest = Schema.Struct({
  number: Schema.Number,
  title: Schema.String,
  state: GitPullRequestState,
  isDraft: Schema.Boolean,
  url: Schema.String,
  checks: GitPullRequestChecks
})
export type GitPullRequest = typeof GitPullRequest.Type

/// The current branch's pull request, looked up with the machine's `gh`. Null
/// when there is none or it can't be told: a detached HEAD, a non-GitHub
/// remote, or `gh` missing or signed out.
export const GitPullRequestLookup = Schema.Struct({
  pullRequest: Schema.NullOr(GitPullRequest)
})
export type GitPullRequestLookup = typeof GitPullRequestLookup.Type

/// How a file differs on one side of the index, as a source control list
/// shows it: staged (HEAD → index) or unstaged (index → working tree).
export const GitChangeCode = Schema.Literals([
  "added",
  "modified",
  "deleted",
  "renamed",
  "typeChanged",
  "untracked",
  "conflicted"
])
export type GitChangeCode = typeof GitChangeCode.Type

/// One changed path. A path changed both in the index and after it carries
/// both codes; an untracked or conflicted path only `unstaged`.
export const GitStatusEntry = Schema.Struct({
  /// Repository-relative.
  path: Schema.String,
  /// Staged renames only: where the file came from.
  oldPath: Schema.optional(Schema.String),
  staged: Schema.optional(GitChangeCode),
  unstaged: Schema.optional(GitChangeCode)
})
export type GitStatusEntry = typeof GitStatusEntry.Type

/// The repository's changed files, light enough to poll: names and codes only.
export const GitStatus = Schema.Struct({
  repositoryRoot: Schema.String,
  /// Null when HEAD is detached.
  branch: Schema.NullOr(Schema.String),
  entries: Schema.Array(GitStatusEntry),
  /// True when more paths changed than one response carries.
  truncated: Schema.Boolean
})
export type GitStatus = typeof GitStatus.Type

/// Stage, unstage, or discard: repository-relative files in the repository
/// containing `path`. Staging and unstaging without files covers every change.
export const GitFilesRequest = Schema.Struct({
  path: Schema.String,
  files: Schema.optional(Schema.Array(Schema.String))
})
export type GitFilesRequest = typeof GitFilesRequest.Type

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

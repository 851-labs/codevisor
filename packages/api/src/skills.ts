import { Schema } from "effect"

/// How a global skill is materialized in one harness's skills directory.
export const SkillInstallState = Schema.Literals([
  "linked",
  "copied",
  "canonical",
  "notInstalled",
  "broken",
  "conflict"
])
export type SkillInstallState = typeof SkillInstallState.Type

export const SkillHarnessInstall = Schema.Struct({
  harnessId: Schema.String,
  state: SkillInstallState
})
export type SkillHarnessInstall = typeof SkillHarnessInstall.Type

/// A skill in the canonical ~/.agents/skills store, with its per-harness
/// install states.
export const GlobalSkill = Schema.Struct({
  /// Frontmatter name, falling back to the directory name when the SKILL.md
  /// frontmatter is missing or malformed.
  name: Schema.String,
  directoryName: Schema.String,
  description: Schema.optional(Schema.String),
  path: Schema.String,
  invalid: Schema.optional(Schema.Boolean),
  installs: Schema.Array(SkillHarnessInstall)
})
export type GlobalSkill = typeof GlobalSkill.Type

/// A skill found in a harness's own skills directory that is NOT a link into
/// the canonical store: an independent copy or a broken link.
export const HarnessSkill = Schema.Struct({
  harnessId: Schema.String,
  directoryName: Schema.String,
  name: Schema.String,
  description: Schema.optional(Schema.String),
  path: Schema.String,
  classification: Schema.Literals(["independent", "broken"]),
  invalid: Schema.optional(Schema.Boolean),
  /// Directory name of the canonical skill this is a content-identical copy
  /// of, when one exists ("Make global" becomes "replace with link").
  duplicateOf: Schema.optional(Schema.String)
})
export type HarnessSkill = typeof HarnessSkill.Type

export const SkillsHarnessGroup = Schema.Struct({
  harnessId: Schema.String,
  harnessName: Schema.String,
  /// SF Symbol name from the harness catalog, for section icons.
  harnessSymbol: Schema.String,
  skillsDir: Schema.String,
  skills: Schema.Array(HarnessSkill)
})
export type SkillsHarnessGroup = typeof SkillsHarnessGroup.Type

export const SkillsScan = Schema.Struct({
  canonicalDir: Schema.String,
  global: Schema.Array(GlobalSkill),
  harnesses: Schema.Array(SkillsHarnessGroup)
})
export type SkillsScan = typeof SkillsScan.Type

export const CreateSkillRequest = Schema.Struct({
  name: Schema.String,
  description: Schema.String,
  /// Optional pasted SKILL.md content. With frontmatter it is written
  /// verbatim; without, name/description frontmatter is prepended.
  content: Schema.optional(Schema.String)
})
export type CreateSkillRequest = typeof CreateSkillRequest.Type

/// Import a skill folder from a local path on the server's machine into the
/// canonical store.
export const ImportSkillRequest = Schema.Struct({
  path: Schema.String
})
export type ImportSkillRequest = typeof ImportSkillRequest.Type

/// Import skills from a remote source — GitHub/GitLab `owner/repo` shorthand
/// or URLs, git URLs, or any site publishing skills via RFC 8615 well-known
/// endpoints, matching the `npx skills` CLI formats. `skillNames` narrows a
/// multi-skill source to a selection.
export const ImportRemoteSkillRequest = Schema.Struct({
  source: Schema.String,
  skillNames: Schema.optional(Schema.Array(Schema.String))
})
export type ImportRemoteSkillRequest = typeof ImportRemoteSkillRequest.Type

export const DiscoverRemoteSkillsRequest = Schema.Struct({
  source: Schema.String
})
export type DiscoverRemoteSkillsRequest = typeof DiscoverRemoteSkillsRequest.Type

/// One skill a remote source offers, for the pre-import picker.
export const RemoteSkillCandidate = Schema.Struct({
  name: Schema.String,
  directoryName: Schema.String,
  description: Schema.optional(Schema.String),
  alreadyExists: Schema.Boolean
})
export type RemoteSkillCandidate = typeof RemoteSkillCandidate.Type

export const DiscoverRemoteSkillsResult = Schema.Struct({
  skills: Schema.Array(RemoteSkillCandidate)
})
export type DiscoverRemoteSkillsResult = typeof DiscoverRemoteSkillsResult.Type

export const SetSkillInstalledRequest = Schema.Struct({
  installed: Schema.Boolean
})
export type SetSkillInstalledRequest = typeof SetSkillInstalledRequest.Type

/// Promote an independent harness-dir skill into the canonical store.
export const MakeSkillGlobalRequest = Schema.Struct({
  harnessId: Schema.String,
  directoryName: Schema.String
})
export type MakeSkillGlobalRequest = typeof MakeSkillGlobalRequest.Type

/// Sync skills across harnesses: the named skills (or all of them) get
/// linked into every harness that needs a link.
export const SyncSkillsRequest = Schema.Struct({
  directoryNames: Schema.optional(Schema.Array(Schema.String))
})
export type SyncSkillsRequest = typeof SyncSkillsRequest.Type

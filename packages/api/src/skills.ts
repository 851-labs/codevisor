import { Schema } from "effect"

/// A skill in Codevisor's own skill store. Agents read it through the tool
/// gateway's `skills` tool; nothing is written into harness skill folders.
export const Skill = Schema.Struct({
  /// Frontmatter name, falling back to the directory name when the SKILL.md
  /// frontmatter is missing or malformed.
  name: Schema.String,
  directoryName: Schema.String,
  description: Schema.optional(Schema.String),
  path: Schema.String,
  invalid: Schema.optional(Schema.Boolean)
})
export type Skill = typeof Skill.Type

export const SkillsList = Schema.Struct({
  /// The store directory on the server's machine.
  dir: Schema.String,
  skills: Schema.Array(Skill)
})
export type SkillsList = typeof SkillsList.Type

export const CreateSkillRequest = Schema.Struct({
  name: Schema.String,
  description: Schema.String,
  /// Optional pasted SKILL.md content. With frontmatter it is written
  /// verbatim; without, name/description frontmatter is prepended.
  content: Schema.optional(Schema.String)
})
export type CreateSkillRequest = typeof CreateSkillRequest.Type

export const SkillContent = Schema.Struct({
  content: Schema.String
})
export type SkillContent = typeof SkillContent.Type

/// Replace only SKILL.md, keeping the directory and supporting files.
export const UpdateSkillRequest = Schema.Struct({
  content: Schema.String
})
export type UpdateSkillRequest = typeof UpdateSkillRequest.Type

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

import { Schema } from "effect"

export const Skill = Schema.Struct({
  name: Schema.String,
  directoryName: Schema.String,
  description: Schema.optional(Schema.String),
  path: Schema.String,
  invalid: Schema.optional(Schema.Boolean)
})
export type Skill = typeof Skill.Type

export const ComposerSkill = Schema.Struct({
  name: Schema.String,
  description: Schema.optional(Schema.String),
  builtin: Schema.Boolean
})
export type ComposerSkill = typeof ComposerSkill.Type

export const ComposerSkills = Schema.Struct({
  skills: Schema.Array(ComposerSkill)
})
export type ComposerSkills = typeof ComposerSkills.Type

export const SkillsList = Schema.Struct({
  dir: Schema.String,
  skills: Schema.Array(Skill)
})
export type SkillsList = typeof SkillsList.Type

export const CreateSkillRequest = Schema.Struct({
  name: Schema.String,
  description: Schema.String,
  content: Schema.optional(Schema.String)
})
export type CreateSkillRequest = typeof CreateSkillRequest.Type

export const SkillContent = Schema.Struct({
  content: Schema.String
})
export type SkillContent = typeof SkillContent.Type

export const UpdateSkillRequest = Schema.Struct({
  content: Schema.String
})
export type UpdateSkillRequest = typeof UpdateSkillRequest.Type

export const ImportRemoteSkillRequest = Schema.Struct({
  source: Schema.String,
  skillNames: Schema.optional(Schema.Array(Schema.String))
})
export type ImportRemoteSkillRequest = typeof ImportRemoteSkillRequest.Type

export const DiscoverRemoteSkillsRequest = Schema.Struct({
  source: Schema.String
})
export type DiscoverRemoteSkillsRequest = typeof DiscoverRemoteSkillsRequest.Type

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

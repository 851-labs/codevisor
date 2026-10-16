import { Schema } from "effect"

export const BotProject = Schema.Struct({
  projectId: Schema.String,
  folderName: Schema.String,
  branch: Schema.String,
  path: Schema.String
})
export type BotProject = typeof BotProject.Type

export const Bot = Schema.Struct({
  id: Schema.String,
  serverId: Schema.String,
  name: Schema.String,
  symbolName: Schema.String,
  harnessId: Schema.String,
  projectId: Schema.String,
  sessionId: Schema.String,
  workspaceId: Schema.String,
  rootPath: Schema.String,
  projects: Schema.Array(BotProject),
  createdAt: Schema.String,
  updatedAt: Schema.optional(Schema.String)
})
export type Bot = typeof Bot.Type

export const CreateBotRequest = Schema.Struct({
  id: Schema.optional(Schema.String),
  name: Schema.String,
  symbolName: Schema.String,
  harnessId: Schema.String,
  configSelections: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  projectIds: Schema.Array(Schema.String)
})
export type CreateBotRequest = typeof CreateBotRequest.Type

export const UpdateBotRequest = Schema.Struct({
  name: Schema.optional(Schema.String),
  symbolName: Schema.optional(Schema.String)
})
export type UpdateBotRequest = typeof UpdateBotRequest.Type

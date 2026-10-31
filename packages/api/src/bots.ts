import { Schema } from "effect"

import { AttachmentRef } from "./sessions.js"

export const BotProject = Schema.Struct({
  projectId: Schema.String,
  folderName: Schema.String,
  branch: Schema.String,
  path: Schema.String
})
export type BotProject = typeof BotProject.Type

export const BotMode = Schema.Literals(["transcript", "bubbles", "conversation"])
export type BotMode = typeof BotMode.Type

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
  conversational: Schema.Boolean,
  mode: BotMode,
  isArchived: Schema.Boolean,
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
  projectIds: Schema.Array(Schema.String),
  conversational: Schema.optional(Schema.Boolean),
  mode: Schema.optional(BotMode)
})
export type CreateBotRequest = typeof CreateBotRequest.Type

export const UpdateBotRequest = Schema.Struct({
  name: Schema.optional(Schema.String),
  symbolName: Schema.optional(Schema.String),
  conversational: Schema.optional(Schema.Boolean),
  mode: Schema.optional(BotMode),
  isArchived: Schema.optional(Schema.Boolean)
})
export type UpdateBotRequest = typeof UpdateBotRequest.Type

export const AddBotProjectRequest = Schema.Struct({
  projectId: Schema.String
})
export type AddBotProjectRequest = typeof AddBotProjectRequest.Type

export const BotMessageSender = Schema.Literals(["user", "bot", "notice"])
export type BotMessageSender = typeof BotMessageSender.Type

export const BotMessage = Schema.Struct({
  id: Schema.String,
  sessionId: Schema.String,
  sequence: Schema.Number,
  sender: BotMessageSender,
  text: Schema.String,
  attachments: Schema.optional(Schema.Array(AttachmentRef)),
  createdAt: Schema.String
})
export type BotMessage = typeof BotMessage.Type

export const BotConversationPage = Schema.Struct({
  messages: Schema.Array(BotMessage),
  hasMore: Schema.Boolean,
  working: Schema.Boolean
})
export type BotConversationPage = typeof BotConversationPage.Type

export const BotMessageAttachmentInput = Schema.Struct({
  path: Schema.String,
  name: Schema.optional(Schema.String)
})
export type BotMessageAttachmentInput = typeof BotMessageAttachmentInput.Type

export const SendBotMessageRequest = Schema.Struct({
  text: Schema.String,
  attachments: Schema.optional(Schema.Array(BotMessageAttachmentInput))
})
export type SendBotMessageRequest = typeof SendBotMessageRequest.Type

export const BotMessageEventPayload = Schema.Struct({
  message: BotMessage
})
export type BotMessageEventPayload = typeof BotMessageEventPayload.Type

import { Schema } from "effect"

import { AttachmentRef } from "./sessions.js"

export const BotProject = Schema.Struct({
  projectId: Schema.String,
  folderName: Schema.String,
  branch: Schema.String,
  path: Schema.String
})
export type BotProject = typeof BotProject.Type

export const BotMascot = Schema.Struct({
  color: Schema.String,
  hat: Schema.String,
  hatColor: Schema.optional(Schema.String),
  eyewear: Schema.String,
  eyewearColor: Schema.optional(Schema.String)
})
export type BotMascot = typeof BotMascot.Type

export const BotMascotSwatch = Schema.Struct({
  id: Schema.String,
  title: Schema.String,
  hex: Schema.String
})
export type BotMascotSwatch = typeof BotMascotSwatch.Type

export const BotMascotChoice = Schema.Struct({
  id: Schema.String,
  title: Schema.String,
  swatches: Schema.optional(Schema.Array(BotMascotSwatch)),
  hasAuto: Schema.optional(Schema.Boolean)
})
export type BotMascotChoice = typeof BotMascotChoice.Type

export const BotMascotColorChoice = Schema.Struct({
  id: Schema.String,
  title: Schema.String,
  gradient: Schema.Array(Schema.String),
  accent: Schema.optional(Schema.String)
})
export type BotMascotColorChoice = typeof BotMascotColorChoice.Type

export const BotMascotOptions = Schema.Struct({
  colors: Schema.Array(BotMascotColorChoice),
  hats: Schema.Array(BotMascotChoice),
  eyewear: Schema.Array(BotMascotChoice),
  nextBotMascot: BotMascot
})
export type BotMascotOptions = typeof BotMascotOptions.Type

export const Bot = Schema.Struct({
  id: Schema.String,
  serverId: Schema.String,
  name: Schema.String,
  symbolName: Schema.String,
  mascot: BotMascot,
  harnessId: Schema.String,
  configSelections: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  projectId: Schema.String,
  sessionId: Schema.String,
  workspaceId: Schema.String,
  rootPath: Schema.String,
  projects: Schema.Array(BotProject),
  isArchived: Schema.Boolean,
  archivedAt: Schema.optional(Schema.String),
  createdAt: Schema.String,
  updatedAt: Schema.optional(Schema.String)
})
export type Bot = typeof Bot.Type

export const CreateBotRequest = Schema.Struct({
  id: Schema.optional(Schema.String),
  name: Schema.String,
  symbolName: Schema.String,
  mascot: Schema.optional(BotMascot),
  harnessId: Schema.String,
  configSelections: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  projectIds: Schema.Array(Schema.String)
})
export type CreateBotRequest = typeof CreateBotRequest.Type

export const ForkBotRequest = Schema.Struct({
  id: Schema.optional(Schema.String),
  name: Schema.optional(Schema.String),
  mascot: Schema.optional(BotMascot),
  harnessId: Schema.String,
  configSelections: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  moveAgents: Schema.optional(Schema.Boolean)
})
export type ForkBotRequest = typeof ForkBotRequest.Type

export const UpdateBotRequest = Schema.Struct({
  name: Schema.optional(Schema.String),
  symbolName: Schema.optional(Schema.String),
  mascot: Schema.optional(BotMascot),
  isArchived: Schema.optional(Schema.Boolean),
  configSelections: Schema.optional(Schema.Record(Schema.String, Schema.String))
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

import { Schema } from "effect"

import { BotMascot, BotMessageSender } from "./bots.js"
import { AttachmentRef, FileMetadata } from "./sessions.js"

export const FLEET_BOT_IMPORT_PATH = "fleet.bot_import"

export const BotImportProject = Schema.Struct({
  name: Schema.String,
  repoUrl: Schema.String
})
export type BotImportProject = typeof BotImportProject.Type

export const BotImportMessage = Schema.Struct({
  sender: BotMessageSender,
  text: Schema.String,
  attachments: Schema.optional(Schema.Array(AttachmentRef)),
  createdAt: Schema.String
})
export type BotImportMessage = typeof BotImportMessage.Type

export const BotImportSpec = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  symbolName: Schema.String,
  mascot: BotMascot,
  harnessId: Schema.String,
  configSelections: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  projects: Schema.Array(BotImportProject),
  notes: Schema.optional(Schema.String),
  messages: Schema.Array(BotImportMessage)
})
export type BotImportSpec = typeof BotImportSpec.Type

export const BotImportAction = Schema.Union([
  Schema.Struct({ action: Schema.Literal("missing_files"), fileIds: Schema.Array(Schema.String) }),
  Schema.Struct({
    action: Schema.Literal("file"),
    file: FileMetadata,
    offset: Schema.Number,
    data: Schema.String
  }),
  Schema.Struct({ action: Schema.Literal("create"), bot: BotImportSpec }),
  Schema.Struct({ action: Schema.Literal("handoff"), botId: Schema.String, text: Schema.String })
])
export type BotImportAction = typeof BotImportAction.Type

import type { AttachmentRef, Bot, BotMessage, BotMessageSender, Workspace } from "@codevisor/api"
import type { Effect } from "effect"

import type { DatabaseError } from "./errors.js"
import { integer, nullable, rowReader, text } from "./row-reader.js"

export interface BotRow {
  readonly id: string
  readonly server_id: string
  readonly name: string
  readonly symbol_name: string
  readonly slug: string
  readonly project_id: string
  readonly session_id: string
  readonly workspace_id: string
  readonly harness_id: string
  readonly conversational: number
  readonly created_at: string
  readonly updated_at: string | null
}

export interface BotProjectRow {
  readonly bot_id: string
  readonly project_id: string
  readonly folder_name: string
  readonly branch: string
  readonly position: number
}

export const botRows = rowReader<BotRow>({
  id: text,
  server_id: text,
  name: text,
  symbol_name: text,
  slug: text,
  project_id: text,
  session_id: text,
  workspace_id: text,
  harness_id: text,
  conversational: integer,
  created_at: text,
  updated_at: nullable(text)
})

export interface BotMessageRow {
  readonly id: string
  readonly session_id: string
  readonly sequence: number
  readonly sender: string
  readonly text: string
  readonly attachments: string | null
  readonly created_at: string
}

export const botMessageRows = rowReader<BotMessageRow>({
  id: text,
  session_id: text,
  sequence: integer,
  sender: text,
  text,
  attachments: nullable(text),
  created_at: text
})

export interface AppendBotMessageRecord {
  readonly id?: string | undefined
  readonly sender: BotMessageSender
  readonly text: string
  readonly attachments?: ReadonlyArray<AttachmentRef> | undefined
}

export interface BotMessagePage {
  readonly messages: ReadonlyArray<BotMessage>
  readonly hasMore: boolean
}

export const botProjectRows = rowReader<BotProjectRow>({
  bot_id: text,
  project_id: text,
  folder_name: text,
  branch: text,
  position: integer
})

export interface BotProjectRecord {
  readonly projectId: string
  readonly folderName: string
  readonly branch: string
}

export interface CreateBotRecord {
  readonly id: string
  readonly name: string
  readonly symbolName: string
  readonly slug: string
  readonly projectId: string
  readonly sessionId: string
  readonly workspaceId: string
  readonly conversational?: boolean
  readonly projects: ReadonlyArray<BotProjectRecord>
}

export interface UpdateBotRecord {
  readonly name?: string | undefined
  readonly symbolName?: string | undefined
}

export interface BotOwnerQuery {
  readonly projectId?: string
  readonly workspaceId?: string
  readonly sessionId?: string
}

export interface BotsService {
  readonly createBot: (record: CreateBotRecord) => Effect.Effect<Bot, DatabaseError>
  readonly listBots: Effect.Effect<ReadonlyArray<Bot>, DatabaseError>
  readonly getBot: (id: string) => Effect.Effect<Bot | undefined, DatabaseError>
  readonly updateBot: (id: string, record: UpdateBotRecord) => Effect.Effect<Bot, DatabaseError>
  readonly deleteBot: (id: string) => Effect.Effect<void, DatabaseError>
  readonly addBotProject: (
    id: string,
    record: BotProjectRecord
  ) => Effect.Effect<Bot, DatabaseError>
  readonly removeBotProject: (id: string, projectId: string) => Effect.Effect<Bot, DatabaseError>
  readonly findBotOwning: (query: BotOwnerQuery) => Effect.Effect<Bot | undefined, DatabaseError>
  readonly listBotWorkspaces: (
    botId: string
  ) => Effect.Effect<ReadonlyArray<Workspace>, DatabaseError>
  readonly appendBotMessage: (
    sessionId: string,
    record: AppendBotMessageRecord
  ) => Effect.Effect<{ readonly message: BotMessage; readonly created: boolean }, DatabaseError>
  readonly listBotMessages: (
    sessionId: string,
    before: number | undefined,
    limit: number
  ) => Effect.Effect<BotMessagePage, DatabaseError>
}

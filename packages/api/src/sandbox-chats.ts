import { Schema } from "effect"

import { Labels } from "./labels.js"
import { SessionCreator } from "./session-config.js"
import { FileMetadata } from "./sessions.js"

export const FLEET_SANDBOX_CHATS_PATH = "fleet.sandbox_chats"

export const SavedChatSession = Schema.Struct({
  id: Schema.String,
  title: Schema.String,
  harnessId: Schema.String,
  agentSessionId: Schema.optional(Schema.String),
  createdAt: Schema.String,
  updatedAt: Schema.optional(Schema.String),
  createdBy: Schema.optional(SessionCreator),
  labels: Schema.optional(Labels),
  configSelections: Schema.optional(Schema.Record(Schema.String, Schema.String))
})
export type SavedChatSession = typeof SavedChatSession.Type

export const SavedChatRow = Schema.Record(
  Schema.String,
  Schema.Union([Schema.String, Schema.Number, Schema.Null])
)

export const SavedChatItem = Schema.Struct({
  item: SavedChatRow,
  children: Schema.Record(Schema.String, Schema.Array(SavedChatRow))
})
export type SavedChatItem = typeof SavedChatItem.Type

export const RESTORED_AGENT_SESSION_LABEL = "codevisor-restored-agent-session"

export const SavedChatResume = Schema.Struct({
  agentSessionId: Schema.String,
  files: Schema.Array(Schema.Struct({ path: Schema.String, sizeBytes: Schema.Number }))
})
export type SavedChatResume = typeof SavedChatResume.Type

export const SavedChat = Schema.Struct({
  session: SavedChatSession,
  itemIds: Schema.Array(Schema.String),
  files: Schema.Array(FileMetadata),
  resume: Schema.optional(SavedChatResume)
})
export type SavedChat = typeof SavedChat.Type

export const SavedChatRestore = Schema.Struct({
  startedAt: Schema.String,
  completedAt: Schema.String,
  lines: Schema.Array(Schema.String)
})
export type SavedChatRestore = typeof SavedChatRestore.Type

export const SavedChatPane = Schema.Struct({
  id: Schema.String,
  providerId: Schema.String,
  paneType: Schema.String,
  title: Schema.String,
  resourceKind: Schema.optional(Schema.String),
  resourceId: Schema.optional(Schema.String),
  metadata: Schema.optional(Schema.String),
  createdAt: Schema.String
})
export type SavedChatPane = typeof SavedChatPane.Type

export const SavedChatList = Schema.Struct({
  format: Schema.Number,
  chats: Schema.Array(SavedChat),
  panes: Schema.Array(SavedChatPane)
})
export type SavedChatList = typeof SavedChatList.Type

export const SavedChatFileChunk = Schema.Struct({ data: Schema.String })

export const SandboxChatsAction = Schema.Union([
  Schema.Struct({ action: Schema.Literal("list"), workspaceId: Schema.String }),
  Schema.Struct({ action: Schema.Literal("item"), itemId: Schema.String }),
  Schema.Struct({
    action: Schema.Literal("file"),
    fileId: Schema.String,
    offset: Schema.Number,
    length: Schema.Number
  }),
  Schema.Struct({
    action: Schema.Literal("resume_file"),
    sessionId: Schema.String,
    path: Schema.String,
    offset: Schema.Number,
    length: Schema.Number
  }),
  Schema.Struct({
    action: Schema.Literal("restore_resume_file"),
    format: Schema.Number,
    harnessId: Schema.String,
    path: Schema.String,
    offset: Schema.Number,
    data: Schema.String
  }),
  Schema.Struct({
    action: Schema.Literal("restore_chat"),
    format: Schema.Number,
    workspaceId: Schema.String,
    session: SavedChatSession
  }),
  Schema.Struct({
    action: Schema.Literal("restore_item"),
    format: Schema.Number,
    sessionId: Schema.String,
    item: SavedChatItem
  }),
  Schema.Struct({
    action: Schema.Literal("restore_file"),
    file: FileMetadata,
    offset: Schema.Number,
    data: Schema.String
  }),
  Schema.Struct({
    action: Schema.Literal("restore_pane"),
    format: Schema.Number,
    workspaceId: Schema.String,
    pane: SavedChatPane
  }),
  Schema.Struct({
    action: Schema.Literal("finish_chat"),
    format: Schema.Number,
    sessionId: Schema.String,
    fileIds: Schema.Array(Schema.String),
    note: Schema.optional(Schema.String),
    restore: Schema.optional(SavedChatRestore),
    agentSessionId: Schema.optional(Schema.String)
  })
])
export type SandboxChatsAction = typeof SandboxChatsAction.Type

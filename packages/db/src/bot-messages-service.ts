import { randomUUID } from "node:crypto"

import type { BotImportMessage, BotMessage, BotMessageSender } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"

import { botMessageRows, type BotMessageRow, type BotsService } from "./bot-rows.js"
import { botConversationOfChat, type BotConversation } from "./conversations.js"
import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { parseAttachments, serializeAttachments } from "./message-row-codecs.js"
import { journaledNavigationChanges } from "./navigation-changes.js"
import type { ServiceContext } from "./service-context.js"
import { linkSessionFiles } from "./session-files.js"

const botMessageFromRow = (row: BotMessageRow, sessionId: string): BotMessage => {
  const attachments = parseAttachments(row.attachments)
  return {
    id: row.id,
    sessionId,
    sequence: row.sequence,
    sender: row.sender === "user" || row.sender === "notice" ? row.sender : "bot",
    text: row.text,
    ...(attachments === undefined ? {} : { attachments }),
    createdAt: row.created_at
  }
}

export const makeBotMessagesService = (
  context: ServiceContext
): Pick<
  BotsService,
  "appendBotMessage" | "listBotMessages" | "copyBotMessages" | "importBotMessages"
> => {
  const { sqlite } = context
  const journaled = journaledNavigationChanges(context)

  return {
    appendBotMessage: (rawSessionId, record) =>
      attempt("appendBotMessage", () => {
        const sessionId = canonicalUuid(rawSessionId)
        return sqlite.transaction(() => {
          const conversation = requireConversation(sqlite, sessionId)
          if (record.id !== undefined) {
            const existing = messageIn(sqlite, record.id, conversation)
            if (existing !== undefined) {
              return { message: botMessageFromRow(existing, sessionId), created: false }
            }
          }
          const id = record.id ?? randomUUID()
          sqlite.prepare(botMessageSql.insert).run({
            id,
            conversationId: conversation.conversationId,
            senderId: senderId(record.sender, conversation),
            text: record.text,
            attachments: serializeAttachments(record.attachments),
            createdAt: isoTimestamp()
          })
          return {
            message: botMessageFromRow(requireMessage(sqlite, id, conversation), sessionId),
            created: true
          }
        })()
      }),
    listBotMessages: (rawSessionId, before, limit, sender) =>
      attempt("listBotMessages", () => {
        const sessionId = canonicalUuid(rawSessionId)
        const conversation = botConversationOfChat(sqlite, sessionId)
        if (conversation === undefined) return { messages: [], hasMore: false }
        const rows = botMessagesBefore(sqlite, conversation, { before, limit, sender })
        return {
          messages: rows
            .slice(0, limit)
            .toReversed()
            .map((row) => botMessageFromRow(row, sessionId)),
          hasMore: rows.length > limit
        }
      }),
    copyBotMessages: (rawSourceId, rawTargetId) =>
      attempt("copyBotMessages", () => {
        const sourceId = canonicalUuid(rawSourceId)
        const targetId = canonicalUuid(rawTargetId)
        return journaled((now) => {
          const source = requireConversation(sqlite, sourceId)
          const target = requireConversation(sqlite, targetId)
          const rows = botMessageRows.all(
            sqlite.prepare(botMessageSql.all).all(source.conversationId)
          )
          for (const row of rows) insertCopy(sqlite, row, target)
          sqlite.prepare(botMessageSql.copyFiles).run(targetId, sourceId)
          sqlite.prepare(botMessageSql.announceSession).run(targetId, now)
        })
      }),
    importBotMessages: (rawSessionId, messages) =>
      attempt("importBotMessages", () => {
        const sessionId = canonicalUuid(rawSessionId)
        return journaled((now) => {
          const target = { ...requireConversation(sqlite, sessionId), sessionId }
          messages.forEach((message, index) => importMessage(sqlite, message, index + 1, target))
          sqlite.prepare(botMessageSql.announceSession).run(sessionId, now)
        })
      })
  }
}

const importMessage = (
  sqlite: ServiceContext["sqlite"],
  message: BotImportMessage,
  sequence: number,
  target: BotConversation & { readonly sessionId: string }
) => {
  const attachments = serializeAttachments(message.attachments)
  sqlite.prepare(botMessageSql.copy).run({
    id: randomUUID(),
    conversationId: target.conversationId,
    sequence,
    senderId: senderId(message.sender, target),
    text: message.text,
    attachments,
    createdAt: message.createdAt
  })
  if (attachments !== null) linkSessionFiles(sqlite, target.sessionId, attachments)
}

const requireConversation = (sqlite: ServiceContext["sqlite"], sessionId: string) => {
  const conversation = botConversationOfChat(sqlite, sessionId)
  if (conversation === undefined) throw new Error(`Not a bot's chat: ${sessionId}`)
  return conversation
}

const senderId = (sender: string, conversation: BotConversation): string | null => {
  if (sender === "notice") return null
  return sender === "user" ? conversation.userParticipantId : conversation.botParticipantId
}

const insertCopy = (
  sqlite: ServiceContext["sqlite"],
  row: BotMessageRow,
  target: BotConversation
) =>
  sqlite.prepare(botMessageSql.copy).run({
    id: randomUUID(),
    conversationId: target.conversationId,
    sequence: row.sequence,
    senderId: senderId(row.sender, target),
    text: row.text,
    attachments: row.attachments,
    createdAt: row.created_at
  })

const messageIn = (sqlite: ServiceContext["sqlite"], id: string, conversation: BotConversation) =>
  botMessageRows.maybe(
    sqlite.prepare(botMessageSql.inConversation).get(id, conversation.conversationId)
  )

const requireMessage = (
  sqlite: ServiceContext["sqlite"],
  id: string,
  conversation: BotConversation
) =>
  botMessageRows.one(
    sqlite.prepare(botMessageSql.inConversation).get(id, conversation.conversationId)
  )

interface BotMessageWindow {
  readonly before: number | undefined
  readonly limit: number
  readonly sender: BotMessageSender | undefined
}

const botMessagesBefore = (
  sqlite: ServiceContext["sqlite"],
  conversation: BotConversation,
  window: BotMessageWindow
) => {
  const before = window.before ?? Number.MAX_SAFE_INTEGER
  const sender = window.sender ?? null
  return botMessageRows.all(
    sqlite
      .prepare(botMessageSql.before)
      .all(conversation.conversationId, before, sender, sender, window.limit + 1)
  )
}

const messageColumns = `conversation_messages.id, conversation_messages.sequence,
      conversation_messages.text, conversation_messages.attachments,
      conversation_messages.created_at,
      coalesce((select kind from conversation_participants
        where conversation_participants.id = conversation_messages.sender_id), 'notice') as sender`

const botMessageSql = {
  inConversation: `select ${messageColumns} from conversation_messages
      where id = ? and conversation_id = ?`,
  insert: `insert into conversation_messages (
        id, conversation_id, sequence, sender_id, text, attachments, created_at
      ) values (@id, @conversationId, (
        select coalesce(max(sequence), 0) + 1 from conversation_messages
          where conversation_id = @conversationId
      ), @senderId, @text, @attachments, @createdAt)`,
  all: `select ${messageColumns} from conversation_messages
      where conversation_id = ? order by sequence asc`,
  copy: `insert into conversation_messages (
        id, conversation_id, sequence, sender_id, text, attachments, created_at
      ) values (@id, @conversationId, @sequence, @senderId, @text, @attachments, @createdAt)`,
  copyFiles: `insert or ignore into session_files (session_id, file_id)
               select ?, file_id from session_files where session_id = ?`,
  announceSession: `insert into events (server_id, kind, subject_id, created_at, payload)
               values (coalesce((select value from instance_meta where key = 'adopted-server-id'), 'local'),
                 'navigation.changed', ?, ?, json_object('table', 'sessions'))`,
  before: `select * from (
        select ${messageColumns} from conversation_messages
          where conversation_id = ? and sequence < ?
      ) where (? is null or sender = ?)
      order by sequence desc limit ?`
}

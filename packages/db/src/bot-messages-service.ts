import { randomUUID } from "node:crypto"

import type { BotMessage } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"

import {
  botMessageRows,
  type AppendBotMessageRecord,
  type BotMessageRow,
  type BotsService
} from "./bot-rows.js"
import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { parseAttachments, serializeAttachments } from "./message-row-codecs.js"
import type { ServiceContext } from "./service-context.js"

const botMessageFromRow = (row: BotMessageRow): BotMessage => {
  const attachments = parseAttachments(row.attachments)
  return {
    id: row.id,
    sessionId: row.session_id,
    sequence: row.sequence,
    sender: row.sender === "user" || row.sender === "notice" ? row.sender : "bot",
    text: row.text,
    ...(attachments === undefined ? {} : { attachments }),
    createdAt: row.created_at
  }
}

export const makeBotMessagesService = (
  context: ServiceContext
): Pick<BotsService, "appendBotMessage" | "listBotMessages"> => {
  const { sqlite } = context

  return {
    appendBotMessage: (rawSessionId, record) =>
      attempt("appendBotMessage", () => {
        const sessionId = canonicalUuid(rawSessionId)
        return sqlite.transaction(() => {
          if (record.id !== undefined) {
            const existing = sessionBotMessage(sqlite, record, sessionId)
            if (existing !== undefined) {
              return { message: botMessageFromRow(existing), created: false }
            }
          }
          const id = record.id ?? randomUUID()
          const createdAt = isoTimestamp()
          sqlite
            .prepare(botMessageSql.insert)
            .run(
              id,
              sessionId,
              sessionId,
              record.sender,
              record.text,
              serializeAttachments(record.attachments),
              createdAt
            )
          return {
            message: botMessageFromRow(savedBotMessage(sqlite, id)),
            created: true
          }
        })()
      }),
    listBotMessages: (rawSessionId, before, limit) =>
      attempt("listBotMessages", () => {
        const sessionId = canonicalUuid(rawSessionId)
        const rows = botMessagesBefore(sqlite, sessionId, before, limit)
        return {
          messages: rows.slice(0, limit).toReversed().map(botMessageFromRow),
          hasMore: rows.length > limit
        }
      })
  }
}

const sessionBotMessage = (
  sqlite: ServiceContext["sqlite"],
  record: AppendBotMessageRecord,
  sessionId: string
) => botMessageRows.maybe(sqlite.prepare(botMessageSql.inSession).get(record.id, sessionId))

const savedBotMessage = (sqlite: ServiceContext["sqlite"], id: string) =>
  botMessageRows.one(sqlite.prepare(botMessageSql.byId).get(id))

const botMessagesBefore = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  before: number | undefined,
  limit: number
) =>
  botMessageRows.all(
    sqlite
      .prepare(botMessageSql.before)
      .all(sessionId, before ?? Number.MAX_SAFE_INTEGER, limit + 1)
  )

const botMessageSql = {
  inSession: "select * from bot_messages where id = ? and session_id = ?",
  byId: "select * from bot_messages where id = ?",
  insert: `insert into bot_messages (id, session_id, sequence, sender, text, attachments, created_at)
               values (?, ?, (
                 select coalesce(max(sequence), 0) + 1 from bot_messages where session_id = ?
               ), ?, ?, ?, ?)`,
  before: `select * from bot_messages
               where session_id = ? and sequence < ?
               order by sequence desc limit ?`
}

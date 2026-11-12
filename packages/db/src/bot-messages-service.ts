import { randomUUID } from "node:crypto"

import type { BotMessage, BotMessageSender } from "@codevisor/api"
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
import { journaledNavigationChanges } from "./navigation-changes.js"
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
): Pick<BotsService, "appendBotMessage" | "listBotMessages" | "copyBotMessages"> => {
  const { sqlite } = context
  const journaled = journaledNavigationChanges(context)

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
    listBotMessages: (rawSessionId, before, limit, sender) =>
      attempt("listBotMessages", () => {
        const sessionId = canonicalUuid(rawSessionId)
        const rows = botMessagesBefore(sqlite, sessionId, { before, limit, sender })
        return {
          messages: rows.slice(0, limit).toReversed().map(botMessageFromRow),
          hasMore: rows.length > limit
        }
      }),
    copyBotMessages: (rawSourceId, rawTargetId) =>
      attempt("copyBotMessages", () => {
        const sourceId = canonicalUuid(rawSourceId)
        const targetId = canonicalUuid(rawTargetId)
        return journaled((now) => {
          const rows = botMessageRows.all(sqlite.prepare(botMessageSql.all).all(sourceId))
          for (const row of rows) insertCopy(sqlite, row, targetId)
          sqlite.prepare(botMessageSql.copyFiles).run(targetId, sourceId)
          sqlite.prepare(botMessageSql.announceSession).run(targetId, now)
        })
      })
  }
}

const insertCopy = (sqlite: ServiceContext["sqlite"], row: BotMessageRow, targetId: string) =>
  sqlite
    .prepare(botMessageSql.copy)
    .run(
      randomUUID(),
      targetId,
      row.sequence,
      row.sender,
      row.text,
      row.attachments,
      row.created_at
    )

const sessionBotMessage = (
  sqlite: ServiceContext["sqlite"],
  record: AppendBotMessageRecord,
  sessionId: string
) => botMessageRows.maybe(sqlite.prepare(botMessageSql.inSession).get(record.id, sessionId))

const savedBotMessage = (sqlite: ServiceContext["sqlite"], id: string) =>
  botMessageRows.one(sqlite.prepare(botMessageSql.byId).get(id))

interface BotMessageWindow {
  readonly before: number | undefined
  readonly limit: number
  readonly sender: BotMessageSender | undefined
}

const botMessagesBefore = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string,
  window: BotMessageWindow
) => {
  const before = window.before ?? Number.MAX_SAFE_INTEGER
  const sender = window.sender ?? null
  return botMessageRows.all(
    sqlite.prepare(botMessageSql.before).all(sessionId, before, sender, sender, window.limit + 1)
  )
}

const botMessageSql = {
  inSession: "select * from bot_messages where id = ? and session_id = ?",
  byId: "select * from bot_messages where id = ?",
  insert: `insert into bot_messages (id, session_id, sequence, sender, text, attachments, created_at)
               values (?, ?, (
                 select coalesce(max(sequence), 0) + 1 from bot_messages where session_id = ?
               ), ?, ?, ?, ?)`,
  all: "select * from bot_messages where session_id = ? order by sequence asc",
  copy: `insert into bot_messages (id, session_id, sequence, sender, text, attachments, created_at)
               values (?, ?, ?, ?, ?, ?, ?)`,
  copyFiles: `insert or ignore into session_files (session_id, file_id)
               select ?, file_id from session_files where session_id = ?`,
  announceSession: `insert into events (server_id, kind, subject_id, created_at, payload)
               values (coalesce((select value from instance_meta where key = 'adopted-server-id'), 'local'),
                 'navigation.changed', ?, ?, json_object('table', 'sessions'))`,
  before: `select * from bot_messages
               where session_id = ? and sequence < ? and (? is null or sender = ?)
               order by sequence desc limit ?`
}

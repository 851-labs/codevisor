import { randomUUID } from "node:crypto"

import type { BotMessage } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"

import { botMessageRows, type BotMessageRow, type BotsService } from "./bot-rows.js"
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
            const existing = botMessageRows.maybe(
              sqlite
                .prepare("select * from bot_messages where id = ? and session_id = ?")
                .get(record.id, sessionId)
            )
            if (existing !== undefined) {
              return { message: botMessageFromRow(existing), created: false }
            }
          }
          const id = record.id ?? randomUUID()
          const createdAt = isoTimestamp()
          sqlite
            .prepare(
              `insert into bot_messages (id, session_id, sequence, sender, text, attachments, created_at)
               values (?, ?, (
                 select coalesce(max(sequence), 0) + 1 from bot_messages where session_id = ?
               ), ?, ?, ?, ?)`
            )
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
            message: botMessageFromRow(
              botMessageRows.one(sqlite.prepare("select * from bot_messages where id = ?").get(id))
            ),
            created: true
          }
        })()
      }),
    listBotMessages: (rawSessionId, before, limit) =>
      attempt("listBotMessages", () => {
        const sessionId = canonicalUuid(rawSessionId)
        const rows = botMessageRows.all(
          sqlite
            .prepare(
              `select * from bot_messages
               where session_id = ? and sequence < ?
               order by sequence desc limit ?`
            )
            .all(sessionId, before ?? Number.MAX_SAFE_INTEGER, limit + 1)
        )
        return {
          messages: rows.slice(0, limit).reverse().map(botMessageFromRow),
          hasMore: rows.length > limit
        }
      })
  }
}

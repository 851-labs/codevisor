import type { BotMessagePreview } from "@codevisor/api"
import type Database from "better-sqlite3"

import type { JsonRecord } from "./event-payloads.js"
import { jsonRecord } from "./event-payloads.js"
import { parseAttachments } from "./message-row-codecs.js"
import type { SessionEventRow } from "./rows.js"

export const botMessagePreviewLength = 280

export const latestBotMessageColumns = `
      (select substr(bm.text, 1, ${botMessagePreviewLength}) from bot_messages bm
        where bm.session_id = sessions.id and bm.sender != 'user'
        order by bm.sequence desc limit 1) as latest_bot_message_text,
      (select bm.attachments from bot_messages bm
        where bm.session_id = sessions.id and bm.sender != 'user'
        order by bm.sequence desc limit 1) as latest_bot_message_attachments`

export const isBotConversation = (sqlite: Database.Database, sessionId: string): boolean =>
  sqlite.prepare(botConversationSql).get(sessionId) !== undefined

export const projectBotConversationAttention = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord
): void => {
  if (isTurnEnd(event, payload)) endBotTurn(sqlite, event.session_id)
  if (deliversBotMessage(event, payload)) recordDeliveredBotMessage(sqlite, event.session_id)
}

export const botMessagePreview = (
  text: string | null | undefined,
  attachments: string | null | undefined
): BotMessagePreview | undefined => {
  if (text === null || text === undefined) return undefined
  const attachmentNames = (parseAttachments(attachments ?? null) ?? []).map((file) => file.name)
  return { text, attachmentNames }
}

export const isTurnEnd = (event: SessionEventRow, payload: JsonRecord): boolean =>
  event.kind === "session.error" ||
  (event.kind === "session.updated" &&
    (payload.turnState === "ended" || typeof payload.stopReason === "string"))

const deliversBotMessage = (event: SessionEventRow, payload: JsonRecord): boolean => {
  if (event.kind !== "bot.message") return false
  const sender = jsonRecord(payload.message)?.sender
  return sender === "bot" || sender === "notice"
}

const endBotTurn = (sqlite: Database.Database, sessionId: string): void => {
  sqlite.prepare(botAttentionSql.endTurn).run(sessionId)
}

const recordDeliveredBotMessage = (sqlite: Database.Database, sessionId: string): void => {
  sqlite.prepare(botAttentionSql.deliverMessage).run(sessionId)
}

const botConversationSql =
  "select 1 from bots where session_id = ? collate nocase and conversational = 1"

const botAttentionSql = {
  endTurn: `update session_attention set turn_active = 0, pending_finish = 0, settle_due_at = null
    where session_id = ?`,
  deliverMessage:
    "update session_attention set attention_revision = attention_revision + 1 where session_id = ?"
}

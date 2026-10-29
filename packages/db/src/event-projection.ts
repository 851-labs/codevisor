import type Database from "better-sqlite3"

import {
  chatRouteForId,
  chatState,
  ensureAssistantChatItem,
  finishAssistantChatItem
} from "./chat-items.js"
import { projectChatOutput } from "./chat-output-projection.js"
import { idRows, revisionRows } from "./common-rows.js"
import { jsonRecord, type JsonRecord } from "./event-payloads.js"
import { clearFreshAgentSessionSql } from "./fresh-agent-sessions-service.js"
import type { SessionEventRow } from "./rows.js"
import { projectSessionEventState } from "./session-event-state.js"
import { projectTranscriptState } from "./transcript-state.js"

const startAssistantTurn = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  sessionId: string
): string => {
  const turnId = typeof payload.turnId === "string" ? payload.turnId : undefined
  const itemId = ensureAssistantChatItem(sqlite, sessionId, event.created_at, turnId)
  sqlite.prepare(startAssistantTurnSql).run(event.created_at, event.created_at, itemId)
  return itemId
}

const resolveTerminalAssistant = (
  sqlite: Database.Database,
  payload: JsonRecord,
  sessionId: string
): string | undefined => {
  const turnId = typeof payload.turnId === "string" ? payload.turnId : undefined
  const currentItemId = chatState(sqlite, sessionId).current_item_id ?? undefined
  const itemId =
    chatRouteForId(sqlite, sessionId, "turn", turnId) ??
    currentItemId ??
    latestStreamingAssistant(sqlite, sessionId)
  return itemId
}

const terminalStopDetail = (event: SessionEventRow, payload: JsonRecord): string | undefined => {
  if (typeof payload.stopDetail === "string") return payload.stopDetail
  if (event.kind === "session.error" && typeof payload.message === "string") return payload.message
  return undefined
}

const completeTerminalAssistant = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  sessionId: string,
  itemId: string
): void => {
  finishAssistantChatItem(
    sqlite,
    sessionId,
    itemId,
    event.created_at,
    typeof payload.stopReason === "string" ? payload.stopReason : undefined,
    terminalStopDetail(event, payload),
    typeof payload.stopKind === "string" ? payload.stopKind : undefined,
    payload.retryable === true,
    event.kind === "session.error"
  )
  sqlite.prepare(clearCurrentItemSql).run(sessionId)
}

const projectTerminalChat = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  sessionId: string
): string | undefined => {
  const itemId = resolveTerminalAssistant(sqlite, payload, sessionId)
  if (itemId !== undefined) {
    completeTerminalAssistant(sqlite, event, payload, sessionId, itemId)
  }
  return itemId
}

export const projectChatEvent = (
  sqlite: Database.Database,
  event: SessionEventRow
): string | undefined => {
  const payload = jsonRecord(JSON.parse(event.payload))
  if (payload === undefined) return undefined
  const sessionId = event.session_id
  let itemId: string | undefined

  if (event.kind === "session.updated" && payload.turnState === "started") {
    itemId = startAssistantTurn(sqlite, event, payload, sessionId)
    sqlite.prepare(clearFreshAgentSessionSql).run(sessionId)
  } else if (event.kind === "session.output") {
    itemId = projectChatOutput(sqlite, event, payload, sessionId)
  } else if (
    event.kind === "session.error" ||
    (event.kind === "session.updated" &&
      (payload.turnState === "ended" || typeof payload.stopReason === "string"))
  ) {
    itemId = projectTerminalChat(sqlite, event, payload, sessionId)
  }

  if (itemId !== undefined) {
    sqlite.prepare(sessionEventSql.linkChatItem).run(itemId, sessionId, event.revision)
  }

  projectSessionEventState(sqlite, event, payload, sessionId)
  projectTranscriptState(sqlite, event, itemId, payload)
  return itemId
}

export const insertSessionEvent = (
  sqlite: Database.Database,
  row: Omit<SessionEventRow, "revision" | "chat_item_id"> & {
    readonly chat_item_id?: string | null
  }
): SessionEventRow => {
  const revision = nextSessionRevision(sqlite, row.session_id)
  const event: SessionEventRow = {
    ...row,
    revision,
    chat_item_id: row.chat_item_id ?? null
  }
  sqlite
    .prepare(sessionEventSql.insert)
    .run(
      event.session_id,
      event.revision,
      event.global_event_id,
      event.server_id,
      event.kind,
      event.created_at,
      event.payload,
      event.chat_item_id
    )
  return event
}

const latestStreamingAssistant = (
  sqlite: Database.Database,
  sessionId: string
): string | undefined =>
  idRows.maybe(sqlite.prepare(latestStreamingAssistantSql).get(sessionId))?.id

const nextSessionRevision = (sqlite: Database.Database, sessionId: string): number =>
  revisionRows.one(sqlite.prepare(bumpSessionRevisionSql).get(sessionId)).revision

const startAssistantTurnSql =
  "update chat_items set started_at = coalesce(started_at, ?), updated_at = ? where id = ?"

const latestStreamingAssistantSql = `select id from chat_items
             where session_id = ? and role = 'assistant' and status = 'streaming'
             order by position desc limit 1`

const clearCurrentItemSql =
  "update session_chat_state set current_item_id = null where session_id = ?"

const bumpSessionRevisionSql =
  "update sessions set revision = revision + 1 where id = ? returning revision"

const sessionEventSql = {
  linkChatItem: "update session_events set chat_item_id = ? where session_id = ? and revision = ?",
  insert: `insert into session_events (
        session_id, revision, global_event_id, server_id, kind, created_at, payload, chat_item_id
      ) values (?, ?, ?, ?, ?, ?, ?, ?)`
}

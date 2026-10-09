import type Database from "better-sqlite3"

import {
  chatRoute,
  chatState,
  ensureAssistantChatItem,
  finishAssistantChatItem
} from "./chat-items.js"
import { projectChatOutput } from "./chat-output-projection.js"
import { jsonRecord, type JsonRecord } from "./event-payloads.js"
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
  sqlite
    .prepare(
      "update chat_items set started_at = coalesce(started_at, ?), updated_at = ? where id = ?"
    )
    .run(event.created_at, event.created_at, itemId)
  return itemId
}

const resolveTerminalAssistant = (
  sqlite: Database.Database,
  payload: JsonRecord,
  sessionId: string
): string | undefined => {
  const turnId = typeof payload.turnId === "string" ? payload.turnId : undefined
  const currentItemId = chatState(sqlite, sessionId).current_item_id ?? undefined
  const latestStreamingItem = (): string | undefined =>
    (
      sqlite
        .prepare(
          `select id from chat_items
             where session_id = ? and role = 'assistant' and status = 'streaming'
             order by position desc limit 1`
        )
        .get(sessionId) as { readonly id: string } | undefined
    )?.id
  const itemId =
    (turnId === undefined ? undefined : chatRoute(sqlite, sessionId, `turn:${turnId}`)) ??
    currentItemId ??
    latestStreamingItem()
  return itemId
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
    typeof payload.stopDetail === "string"
      ? payload.stopDetail
      : event.kind === "session.error" && typeof payload.message === "string"
        ? payload.message
        : undefined,
    typeof payload.stopKind === "string" ? payload.stopKind : undefined,
    payload.retryable === true,
    event.kind === "session.error"
  )
  sqlite
    .prepare("update session_chat_state set current_item_id = null where session_id = ?")
    .run(sessionId)
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
  if (payload === undefined) return
  const sessionId = event.session_id
  let itemId: string | undefined

  if (event.kind === "session.updated" && payload.turnState === "started") {
    itemId = startAssistantTurn(sqlite, event, payload, sessionId)
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
    sqlite
      .prepare("update session_events set chat_item_id = ? where session_id = ? and revision = ?")
      .run(itemId, sessionId, event.revision)
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
  const revision = Number(
    (
      sqlite
        .prepare("update sessions set revision = revision + 1 where id = ? returning revision")
        .get(row.session_id) as { revision: number }
    ).revision
  )
  const event: SessionEventRow = {
    ...row,
    revision,
    chat_item_id: row.chat_item_id ?? null
  }
  sqlite
    .prepare(
      `insert into session_events (
        session_id, revision, global_event_id, server_id, kind, created_at, payload, chat_item_id
      ) values (?, ?, ?, ?, ?, ?, ?, ?)`
    )
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

import { randomUUID } from "node:crypto"

import type {
  AttachmentRef,
  MessagePhase,
  SessionGoal,
  TranscriptBodyResource
} from "@codevisor/api"
import { SessionGoal as SessionGoalSchema } from "@codevisor/api"
import type Database from "better-sqlite3"
import { Schema } from "effect"

import { serializeAttachments } from "./row-mappers.js"
import { transcriptTextResource } from "./transcript-bodies.js"
import { appendTranscriptText, readTranscriptText } from "./transcript-state.js"

export const chatState = (
  sqlite: Database.Database,
  sessionId: string
): { next_position: number; current_item_id: string | null } => {
  sqlite
    .prepare(
      `insert into session_chat_state (session_id, next_position, current_item_id)
       values (?, 0, null) on conflict(session_id) do nothing`
    )
    .run(sessionId)
  return sqlite
    .prepare("select next_position, current_item_id from session_chat_state where session_id = ?")
    .get(sessionId) as { next_position: number; current_item_id: string | null }
}

export const upsertChatPart = (
  sqlite: Database.Database,
  itemId: string,
  kind: "text" | "plan",
  text: string
): void => {
  const position = kind === "text" ? 0 : 1
  sqlite
    .prepare(
      `insert into chat_parts (id, item_id, position, kind, text, data_json, revision)
       values (?, ?, ?, ?, ?, null, 1)
       on conflict(item_id, position) do update set
         kind = excluded.kind, text = excluded.text, revision = chat_parts.revision + 1`
    )
    .run(`${itemId}:${kind}`, itemId, position, kind, text)
}

export const createChatItem = (
  sqlite: Database.Database,
  sessionId: string,
  role: "user" | "assistant" | "system" | "tool",
  createdAt: string,
  options: {
    readonly id?: string
    readonly position?: number
    readonly text?: string
    readonly messageId?: string
    readonly planDocument?: string
    readonly status: "streaming" | "complete" | "failed"
    readonly turnId?: string
    readonly startedAt?: string
    readonly completedAt?: string
    readonly stopReason?: string
    readonly stopDetail?: string
    readonly retryable?: boolean
    readonly attachments?: ReadonlyArray<AttachmentRef>
    readonly hasDetails?: boolean
    readonly revision?: number
  }
): string => {
  const state = chatState(sqlite, sessionId)
  const id = options.id ?? randomUUID()
  const position = options.position ?? state.next_position
  sqlite
    .prepare(
      `insert into chat_items (
        id, session_id, position, role, message_id, status, created_at, updated_at, turn_id,
        started_at, completed_at, stop_reason, stop_detail, retryable, attachments, has_details, revision
      ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      on conflict(id) do nothing`
    )
    .run(
      id,
      sessionId,
      position,
      role,
      options.messageId ?? null,
      options.status,
      createdAt,
      options.completedAt ?? createdAt,
      options.turnId ?? null,
      options.startedAt ?? null,
      options.completedAt ?? null,
      options.stopReason ?? null,
      options.stopDetail ?? null,
      Number(options.retryable === true),
      serializeAttachments(options.attachments),
      options.hasDetails === true ? 1 : 0,
      options.revision ?? 1
    )
  if (options.text !== undefined) {
    const migrated =
      sqlite
        .prepare(
          "select 1 from backfill_jobs where id = 'persisted-transcript-state-v1' and state = 'completed'"
        )
        .get() !== undefined
    upsertChatPart(sqlite, id, "text", migrated ? options.text.slice(0, 24_000) : options.text)
    seedStandaloneText(sqlite, id, options.text, options.messageId)
  }
  if (options.planDocument !== undefined) {
    const migrated =
      sqlite
        .prepare(
          "select 1 from backfill_jobs where id = 'persisted-transcript-state-v1' and state = 'completed'"
        )
        .get() !== undefined
    upsertChatPart(
      sqlite,
      id,
      "plan",
      migrated ? options.planDocument.slice(0, 24_000) : options.planDocument
    )
    sqlite
      .prepare(
        `insert into transcript_entries(item_id, entry_key, position, revision, category, payload)
      values (?, 'plan', 1, 0, 'plan', '{"sessionUpdate":"plan_document"}') on conflict do nothing`
      )
      .run(id)
    appendTranscriptText(sqlite, id, "plan", options.planDocument, true)
  }
  sqlite
    .prepare(
      `update session_chat_state set
         next_position = max(next_position, ?),
         current_item_id = case when ? = 'assistant' and ? = 'streaming' then ? else current_item_id end
       where session_id = ?`
    )
    .run(position + 1, role, options.status, id, sessionId)
  return id
}

export const setChatRoute = (
  sqlite: Database.Database,
  sessionId: string,
  key: string,
  itemId: string
): void => {
  sqlite
    .prepare(
      `insert into chat_item_routes (session_id, route_key, item_id) values (?, ?, ?)
       on conflict(session_id, route_key) do update set item_id = excluded.item_id`
    )
    .run(sessionId, key, itemId)
}

export const chatRoute = (
  sqlite: Database.Database,
  sessionId: string,
  key: string
): string | undefined =>
  (
    sqlite
      .prepare("select item_id from chat_item_routes where session_id = ? and route_key = ?")
      .get(sessionId, key) as { item_id: string } | undefined
  )?.item_id

export const ensureAssistantChatItem = (
  sqlite: Database.Database,
  sessionId: string,
  createdAt: string,
  turnId?: string
): string => {
  if (turnId !== undefined) {
    const routed = chatRoute(sqlite, sessionId, `turn:${turnId}`)
    if (routed !== undefined) return routed
  }
  const current = chatState(sqlite, sessionId).current_item_id
  if (current !== null) {
    // Dispatch can create the waiting row before the provider allocates a turn
    // id. Bind that id to the same row when startup finishes, including routing
    // late terminal events after another turn has become current.
    if (turnId !== undefined) {
      const bound = sqlite
        .prepare("update chat_items set turn_id = ? where id = ? and turn_id is null")
        .run(turnId, current)
      if (bound.changes > 0) setChatRoute(sqlite, sessionId, `turn:${turnId}`, current)
    }
    return current
  }
  const id = createChatItem(sqlite, sessionId, "assistant", createdAt, {
    status: "streaming",
    ...(turnId === undefined ? {} : { turnId })
  })
  if (turnId !== undefined) setChatRoute(sqlite, sessionId, `turn:${turnId}`, id)
  return id
}

export const chatAssistantSummary = (
  sqlite: Database.Database,
  _sessionId: string,
  itemId: string
): {
  text: string
  planDocument?: string
  messageId?: string
  phase?: MessagePhase
  textGeneration?: number
  textRevision?: number
  textPosition?: number
  textResource?: TranscriptBodyResource | undefined
  planResource?: TranscriptBodyResource | undefined
} => {
  // Indexed state lookup; no provider log scan, including while a turn streams.
  const row = sqlite
    .prepare(
      `select entry_key, payload, phase, revision, position from transcript_entries
    where item_id = ? and parent_id = '' and category = 'text' and text_length > 0
      and coalesce(phase, '') != 'commentary'
    order by position desc limit 1`
    )
    .get(itemId) as
    | {
        entry_key: string
        payload: string
        phase: MessagePhase | null
        revision: number
        position: number
      }
    | undefined
  const payload =
    row === undefined
      ? undefined
      : (JSON.parse(row.payload) as { messageId?: string; generation?: number })
  const plan = sqlite
    .prepare("select 1 from transcript_entries where item_id = ? and entry_key = 'plan'")
    .get(itemId)
  return {
    text: row === undefined ? "" : readTranscriptText(sqlite, itemId, row.entry_key, 24_000),
    ...(plan === undefined
      ? {}
      : {
          planResource: transcriptTextResource(sqlite, itemId, "plan"),
          planDocument: readTranscriptText(sqlite, itemId, "plan", 24_000)
        }),
    ...(row === undefined
      ? {}
      : {
          textResource: transcriptTextResource(sqlite, itemId, row.entry_key),
          messageId: payload?.messageId ?? row.entry_key,
          textGeneration: payload?.generation ?? 0,
          textRevision: row.revision,
          textPosition: row.position
        }),
    ...(row?.phase == null ? {} : { phase: row.phase })
  }
}

export const sessionGoalSnapshot = (
  sqlite: Database.Database,
  sessionId: string
): SessionGoal | undefined => {
  const row = sqlite.prepare("select goal_state from sessions where id = ?").get(sessionId) as
    | { goal_state: string | null }
    | undefined
  if (row?.goal_state == null) return undefined
  return Schema.decodeUnknownSync(SessionGoalSchema)(JSON.parse(row.goal_state))
}

export const finishAssistantChatItem = (
  sqlite: Database.Database,
  sessionId: string,
  itemId: string,
  completedAt: string,
  stopReason?: string,
  stopDetail?: string,
  stopKind?: string,
  retryable = false,
  failed = false
): void => {
  const summary = chatAssistantSummary(sqlite, sessionId, itemId)
  upsertChatPart(sqlite, itemId, "text", summary.text)
  if (summary.planDocument !== undefined) {
    upsertChatPart(sqlite, itemId, "plan", summary.planDocument)
  }
  sqlite
    .prepare(
      `update chat_items set status = ?, completed_at = ?, updated_at = ?,
       stop_reason = coalesce(?, stop_reason), stop_detail = coalesce(?, stop_detail),
       stop_kind = coalesce(?, stop_kind),
       retryable = ?,
       revision = revision + 1 where id = ?`
    )
    .run(
      failed ? "failed" : "complete",
      completedAt,
      completedAt,
      stopReason ?? null,
      stopDetail ?? null,
      stopKind ?? null,
      retryable ? 1 : 0,
      itemId
    )
}

/** Imports and user messages have no token stream to materialize them. */
export const seedStandaloneText = (
  db: Database.Database,
  itemId: string,
  text: string,
  messageId?: string
): void => {
  if (text.length === 0) return
  const key = messageId === undefined ? "imported-text" : `message::${messageId}`
  const result = db
    .prepare(
      `insert into transcript_entries (item_id, entry_key, position, revision, category, payload)
    values (?, ?, 0, 0, 'text', ?) on conflict(item_id, entry_key) do nothing`
    )
    .run(
      itemId,
      key,
      JSON.stringify({
        sessionUpdate: "agent_message_chunk",
        messageId: messageId ?? key,
        generation: 0
      })
    )
  if (result.changes > 0) appendTranscriptText(db, itemId, key, text)
}

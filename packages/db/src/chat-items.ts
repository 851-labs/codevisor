import type { AttachmentRef, MessagePhase, SessionGoal } from "@codevisor/api"
import { SessionGoal as SessionGoalSchema } from "@codevisor/api"
import type Database from "better-sqlite3"
import { Schema } from "effect"
import { randomUUID } from "node:crypto"
import { jsonRecord, payloadText } from "./event-payloads.js"
import { serializeAttachments } from "./row-mappers.js"

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
  if (options.text !== undefined) upsertChatPart(sqlite, id, "text", options.text)
  if (options.planDocument !== undefined) upsertChatPart(sqlite, id, "plan", options.planDocument)
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
  if (current !== null) return current
  const id = createChatItem(sqlite, sessionId, "assistant", createdAt, {
    status: "streaming",
    ...(turnId === undefined ? {} : { turnId })
  })
  if (turnId !== undefined) setChatRoute(sqlite, sessionId, `turn:${turnId}`, id)
  return id
}

export const chatAssistantSummary = (
  sqlite: Database.Database,
  sessionId: string,
  itemId: string
): { text: string; planDocument?: string; messageId?: string; phase?: MessagePhase } => {
  const rows = sqlite
    .prepare(
      `select payload from session_events
       where session_id = ? and chat_item_id = ? and kind = 'session.output'
       order by revision asc`
    )
    .all(sessionId, itemId) as ReadonlyArray<{ payload: string }>
  const spans: Array<{ chunks: Array<string>; phase?: MessagePhase; messageId?: string }> = []
  const indexById = new Map<string, number>()
  let anonymous = 0
  let planDocument: string | undefined
  let finalized: { readonly markdown: string; readonly messageId?: string } | undefined
  for (const row of rows) {
    const payload = jsonRecord(JSON.parse(row.payload))
    /* v8 ignore next -- session events are encoded from object payloads; this only guards manually corrupted rows. */
    if (payload === undefined) continue
    if (payload.sessionUpdate === "plan_document" && typeof payload.markdown === "string") {
      planDocument = payload.markdown
      continue
    }
    if (
      payload.sessionUpdate === "assistant_message_finalized" &&
      typeof payload.markdown === "string"
    ) {
      finalized = {
        markdown: payload.markdown,
        ...(typeof payload.messageId === "string" ? { messageId: payload.messageId } : {})
      }
      continue
    }
    const direct = payload.role === "assistant" && typeof payload.text === "string"
    if (
      !direct &&
      (payload.sessionUpdate !== "agent_message_chunk" ||
        typeof payload.parentToolCallId === "string")
    ) {
      anonymous += 1
      continue
    }
    /* v8 ignore next -- projected answer events always carry text; this only guards manually corrupted rows. */
    const text = payloadText(payload) ?? ""
    const suppliedMessageId = typeof payload.messageId === "string" ? payload.messageId : undefined
    // A zero-length chunk can retroactively classify a previously streamed
    // span. Keep it in the semantic summary even though it has no visible
    // text; dropping it resurrects Claude preambles as final answers when a
    // client reopens the chat after the following tool call has started.
    if (text.length === 0 && suppliedMessageId === undefined) continue
    const messageId = suppliedMessageId ?? `anonymous:${anonymous}`
    let index = indexById.get(messageId)
    if (index === undefined) {
      index = spans.length
      indexById.set(messageId, index)
      // Anonymous spans have no provider identity to hand back to clients.
      spans.push(suppliedMessageId === undefined ? { chunks: [] } : { chunks: [], messageId })
    }
    const span = spans[index]
    /* v8 ignore next -- index is created from spans.length immediately before lookup. */
    if (span === undefined) continue
    if (text.length > 0) span.chunks.push(text)
    if (payload.phase === "commentary" || payload.phase === "final") {
      span.phase = payload.phase
    }
  }
  const final = [...spans]
    .reverse()
    .find((span) => span.chunks.length > 0 && span.phase !== "commentary")
  const messageId = finalized?.messageId ?? final?.messageId
  const phase: MessagePhase | undefined = finalized === undefined ? final?.phase : "final"
  return {
    text: finalized?.markdown ?? final?.chunks.join("") ?? "",
    ...(planDocument === undefined ? {} : { planDocument }),
    ...(messageId === undefined ? {} : { messageId }),
    ...(phase === undefined ? {} : { phase })
  }
}

/// Goal updates live in the durable session log rather than the transcript
/// projection. Snapshot the newest one alongside the transcript cursor so a
/// client that opens after the update cannot skip it by subscribing from the
/// newer cursor.
export const sessionGoalSnapshot = (
  sqlite: Database.Database,
  sessionId: string
): SessionGoal | undefined => {
  const row = sqlite
    .prepare(
      `select payload from session_events
       where session_id = ? and kind = 'session.updated'
         and (json_type(payload, '$.goal') = 'object'
           or json_extract(payload, '$.goalCleared') = 1)
       order by revision desc limit 1`
    )
    .get(sessionId) as { readonly payload: string } | undefined
  if (row === undefined) return undefined
  const payload = jsonRecord(JSON.parse(row.payload))
  if (payload?.goalCleared === true) return undefined
  try {
    return Schema.decodeUnknownSync(SessionGoalSchema)(payload?.goal)
  } catch {
    /* v8 ignore next -- only manually corrupted session events can reach this path. */
    return undefined
  }
}

export const finishAssistantChatItem = (
  sqlite: Database.Database,
  sessionId: string,
  itemId: string,
  completedAt: string,
  stopReason?: string,
  stopDetail?: string,
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
       retryable = ?,
       revision = revision + 1 where id = ?`
    )
    .run(
      failed ? "failed" : "complete",
      completedAt,
      completedAt,
      stopReason ?? null,
      stopDetail ?? null,
      retryable ? 1 : 0,
      itemId
    )
}

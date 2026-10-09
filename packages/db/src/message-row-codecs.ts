import type { AttachmentRef, EventEnvelope, PromptQueueItem, TranscriptItem } from "@codevisor/api"
import type Database from "better-sqlite3"

import { withChatItemId } from "./event-payloads.js"
import type { ChatItemRow, EventRow, PromptQueueRow, SessionEventRow } from "./rows.js"

export const serializeAttachments = (
  attachments: ReadonlyArray<AttachmentRef> | undefined
): string | null =>
  attachments === undefined || attachments.length === 0 ? null : JSON.stringify(attachments)

export const parseAttachments = (raw: string | null): ReadonlyArray<AttachmentRef> | undefined => {
  if (raw === null) {
    return undefined
  }
  const parsed = JSON.parse(raw) as ReadonlyArray<AttachmentRef>
  return parsed.length === 0 ? undefined : parsed
}

export const transcriptFromChatRow = (row: ChatItemRow): TranscriptItem => {
  const attachments = parseAttachments(row.attachments)
  /* v8 ignore next 3 -- the query filters roles and chat_items enforces the same CHECK constraint. */
  if (row.role !== "user" && row.role !== "assistant") {
    throw new Error(`Unsupported transcript role: ${row.role}`)
  }
  return {
    id: row.id,
    sessionId: row.session_id,
    sequence: row.position,
    role: row.role,
    // User identity must survive optimistic echo -> durable history. Assistant
    // messageId belongs to the current answer candidate and is mapped separately.
    ...(row.role === "user" && row.message_id !== null ? { messageId: row.message_id } : {}),
    text: row.text,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    isGenerating: row.status === "streaming",
    hasDetails: row.has_details === 1,
    ...(row.turn_id === null ? {} : { turnId: row.turn_id }),
    ...(row.started_at === null ? {} : { startedAt: row.started_at }),
    ...(row.completed_at === null ? {} : { endedAt: row.completed_at }),
    ...(row.plan_proposed_at === null ? {} : { planProposedAt: row.plan_proposed_at }),
    ...(row.plan_resumed_at === null ? {} : { planResumedAt: row.plan_resumed_at }),
    ...(row.stop_reason === null ? {} : { stopReason: row.stop_reason }),
    ...(row.stop_detail === null ? {} : { stopDetail: row.stop_detail }),
    ...(row.stop_kind === "usageLimit" ? { stopKind: "usageLimit" as const } : {}),
    ...(row.retryable === 1 ? { retryable: true } : {}),
    ...(row.plan_document === null ? {} : { planDocument: row.plan_document }),
    ...(attachments === undefined ? {} : { attachments }),
    revision: row.revision
  }
}

export const promptQueueFromRow = (row: PromptQueueRow): PromptQueueItem => {
  const attachments = parseAttachments(row.attachments)
  return {
    id: row.id,
    sessionId: row.session_id,
    text: row.text,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    ...(attachments === undefined ? {} : { attachments }),
    ...(row.client_id == null ? {} : { clientId: row.client_id })
  }
}

export const listPromptQueueSync = (
  sqlite: Database.Database,
  sessionId: string,
  state: PromptQueueRow["state"] = "pending"
): ReadonlyArray<PromptQueueItem> =>
  sqlite
    .prepare(
      `select * from prompt_queue_items
       where session_id = ? and state = ?
       order by position asc, created_at asc, rowid asc`
    )
    .all(sessionId, state)
    .map((row) => promptQueueFromRow(row as PromptQueueRow))

export const eventFromRow = (row: EventRow): EventEnvelope => ({
  id: row.id,
  globalEventId: row.id,
  serverId: row.server_id,
  kind: row.kind,
  subjectId: row.subject_id,
  createdAt: row.created_at,
  payload: JSON.parse(row.payload) as unknown
})

export const sessionEventFromRow = (row: SessionEventRow): EventEnvelope => ({
  id: row.revision,
  ...(row.global_event_id === null ? {} : { globalEventId: row.global_event_id }),
  subjectRevision: row.revision,
  serverId: row.server_id,
  kind: row.kind,
  subjectId: row.session_id,
  createdAt: row.created_at,
  payload: withChatItemId(JSON.parse(row.payload) as unknown, row.chat_item_id)
})

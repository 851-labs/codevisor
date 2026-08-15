import type { AttachmentRef } from "@codevisor/api"
import type Database from "better-sqlite3"
import {
  chatRoute,
  chatState,
  createChatItem,
  ensureAssistantChatItem,
  finishAssistantChatItem,
  setChatRoute,
  upsertChatPart
} from "./chat-items.js"
import {
  conversationEventPayload,
  hasRenderableWorkedDetail,
  jsonRecord,
  parseJsonRecord
} from "./event-payloads.js"
import { serializeAttachments } from "./row-mappers.js"
import type { SessionEventRow } from "./rows.js"

export const projectChatEvent = (sqlite: Database.Database, event: SessionEventRow): void => {
  const payload = jsonRecord(JSON.parse(event.payload))
  if (payload === undefined) return
  const sessionId = event.session_id
  let itemId: string | undefined

  if (event.kind === "session.updated" && payload.turnState === "started") {
    const turnId = typeof payload.turnId === "string" ? payload.turnId : undefined
    itemId = ensureAssistantChatItem(sqlite, sessionId, event.created_at, turnId)
    sqlite
      .prepare(
        "update chat_items set started_at = coalesce(started_at, ?), updated_at = ? where id = ?"
      )
      .run(event.created_at, event.created_at, itemId)
  } else if (event.kind === "session.output") {
    const update = typeof payload.sessionUpdate === "string" ? payload.sessionUpdate : undefined
    if (update === "assistant_message_finalized" && typeof payload.markdown === "string") {
      itemId = ensureAssistantChatItem(sqlite, sessionId, event.created_at)
      upsertChatPart(sqlite, itemId, "text", payload.markdown)
      const attachments = Array.isArray(payload.attachments)
        ? (payload.attachments as ReadonlyArray<AttachmentRef>)
        : undefined
      sqlite
        .prepare(
          `update chat_items set attachments = ?, message_id = coalesce(?, message_id),
           updated_at = ?, revision = revision + 1 where id = ?`
        )
        .run(
          serializeAttachments(attachments),
          typeof payload.messageId === "string" ? payload.messageId : null,
          event.created_at,
          itemId
        )
    } else {
      const conversation = conversationEventPayload(payload)
      if (conversation?.role === "user" || conversation?.role === "system") {
        // A response retry reuses the original user message id. The provider
        // still receives a continuation prompt, but the semantic transcript
        // keeps the user's instruction exactly once.
        const existingUser =
          conversation.role === "user" && conversation.messageId !== undefined
            ? (sqlite
                .prepare(
                  "select id from chat_items where session_id = ? and role = 'user' and message_id = ? limit 1"
                )
                .get(sessionId, conversation.messageId) as { readonly id: string } | undefined)
            : undefined
        itemId =
          existingUser?.id ??
          createChatItem(sqlite, sessionId, conversation.role, event.created_at, {
            text: conversation.text,
            ...(conversation.messageId === undefined ? {} : { messageId: conversation.messageId }),
            status: "complete",
            ...(conversation.attachments === undefined
              ? {}
              : { attachments: conversation.attachments })
          })
      } else if (conversation?.role === "assistant") {
        itemId = ensureAssistantChatItem(sqlite, sessionId, event.created_at)
        sqlite
          .prepare(
            `insert into chat_parts (id, item_id, position, kind, text, data_json, revision)
           values (?, ?, 0, 'text', ?, null, 1)
           on conflict(item_id, position) do update set
             text = coalesce(chat_parts.text, '') || excluded.text,
             revision = chat_parts.revision + 1`
          )
          .run(`${itemId}:text`, itemId, conversation.text)
        sqlite
          .prepare(
            `update chat_items set message_id = coalesce(message_id, ?), updated_at = ?,
           revision = revision + 1 where id = ?`
          )
          .run(conversation.messageId ?? null, event.created_at, itemId)
      } else {
        // ACP agents can publish session-scoped metadata (available commands,
        // mode/config changes, usage) as `session.output` before the first
        // prompt. Those events remain in the session event log, but they must
        // not materialize an empty streaming assistant item ahead of the user's
        // first message. Only updates that can render inside an assistant turn
        // belong to the canonical chat projection.
        const rendersInAssistantTurn =
          hasRenderableWorkedDetail(payload) ||
          (update === "plan_document" && typeof payload.markdown === "string")
        if (update !== undefined && rendersInAssistantTurn) {
          const parent =
            typeof payload.parentToolCallId === "string" ? payload.parentToolCallId : undefined
          const toolId = typeof payload.toolCallId === "string" ? payload.toolCallId : undefined
          itemId =
            (parent === undefined ? undefined : chatRoute(sqlite, sessionId, `tool:${parent}`)) ??
            (toolId === undefined ? undefined : chatRoute(sqlite, sessionId, `tool:${toolId}`)) ??
            ensureAssistantChatItem(sqlite, sessionId, event.created_at)
          sqlite
            .prepare(
              `update chat_items set has_details = max(has_details, ?), updated_at = ?,
             revision = revision + 1 where id = ?`
            )
            .run(hasRenderableWorkedDetail(payload) ? 1 : 0, event.created_at, itemId)
          if (update === "plan_document" && typeof payload.markdown === "string") {
            upsertChatPart(sqlite, itemId, "plan", payload.markdown)
          }
          if (toolId !== undefined) setChatRoute(sqlite, sessionId, `tool:${toolId}`, itemId)
        }
      }
    }
  } else if (
    event.kind === "session.error" ||
    (event.kind === "session.updated" &&
      (payload.turnState === "ended" || typeof payload.stopReason === "string"))
  ) {
    const turnId = typeof payload.turnId === "string" ? payload.turnId : undefined
    itemId =
      (turnId === undefined ? undefined : chatRoute(sqlite, sessionId, `turn:${turnId}`)) ??
      chatState(sqlite, sessionId).current_item_id ??
      undefined
    if (itemId !== undefined) {
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
        payload.retryable === true,
        event.kind === "session.error"
      )
      sqlite
        .prepare("update session_chat_state set current_item_id = null where session_id = ?")
        .run(sessionId)
    }
  }

  if (itemId !== undefined) {
    sqlite
      .prepare("update session_events set chat_item_id = ? where session_id = ? and revision = ?")
      .run(itemId, sessionId, event.revision)
  }

  // A question is session-level blocking state, not merely transcript detail.
  // Keep a single current-state projection in the same transaction as the
  // append so reconnect snapshots cannot advance past the event while losing
  // the question needed to release the provider's pending continuation.
  const update = typeof payload.sessionUpdate === "string" ? payload.sessionUpdate : undefined
  if (
    event.kind === "session.output" &&
    update === "question" &&
    typeof payload.questionId === "string" &&
    Array.isArray(payload.questions)
  ) {
    sqlite
      .prepare("update sessions set pending_question = ? where id = ?")
      .run(event.payload, sessionId)
  } else if (
    event.kind === "session.output" &&
    update === "question_resolved" &&
    typeof payload.questionId === "string"
  ) {
    const current = sqlite
      .prepare("select pending_question from sessions where id = ?")
      .get(sessionId) as { readonly pending_question: string | null }
    const projected =
      current.pending_question === null ? undefined : parseJsonRecord(current.pending_question)
    if (projected?.questionId === payload.questionId) {
      sqlite.prepare("update sessions set pending_question = null where id = ?").run(sessionId)
    }
  } else if (
    event.kind === "session.error" ||
    (event.kind === "session.updated" &&
      (payload.turnState === "ended" || typeof payload.stopReason === "string"))
  ) {
    sqlite.prepare("update sessions set pending_question = null where id = ?").run(sessionId)
  }
  if (event.kind === "session.updated" && Array.isArray(payload.backgroundTasks)) {
    sqlite
      .prepare("update sessions set background_tasks = ? where id = ?")
      .run(JSON.stringify(payload.backgroundTasks), sessionId)
  }
  if (
    (event.kind === "session.updated" || event.kind === "session.output") &&
    update === "usage_update"
  ) {
    const cost = jsonRecord(payload.cost)
    const finite = (value: unknown): number | null =>
      typeof value === "number" && Number.isFinite(value) ? value : null
    const costKind = cost?.kind === "reported" || cost?.kind === "estimated" ? cost.kind : null
    sqlite
      .prepare(
        `update sessions set
           usage_used = coalesce(?, usage_used), usage_size = coalesce(?, usage_size),
           input_tokens = coalesce(?, input_tokens),
           cached_input_tokens = coalesce(?, cached_input_tokens),
           output_tokens = coalesce(?, output_tokens),
           reasoning_output_tokens = coalesce(?, reasoning_output_tokens),
           total_tokens = coalesce(?, total_tokens),
           cost_amount = coalesce(?, cost_amount),
           cost_currency = coalesce(?, cost_currency),
           cost_kind = coalesce(?, cost_kind)
         where id = ?`
      )
      .run(
        finite(payload.used),
        finite(payload.size),
        finite(payload.inputTokens),
        finite(payload.cachedInputTokens),
        finite(payload.outputTokens),
        finite(payload.reasoningOutputTokens),
        finite(payload.totalTokens),
        finite(cost?.amount),
        typeof cost?.currency === "string" ? cost.currency : null,
        costKind,
        sessionId
      )
  }
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

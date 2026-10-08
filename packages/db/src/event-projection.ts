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
  jsonRecord
} from "./event-payloads.js"
import { parseAttachments, serializeAttachments } from "./row-mappers.js"
import type { SessionEventRow } from "./rows.js"
import { projectSessionEventState } from "./session-event-state.js"
import { projectTranscriptState } from "./transcript-state.js"

export const projectChatEvent = (
  sqlite: Database.Database,
  event: SessionEventRow
): string | undefined => {
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
      upsertChatPart(sqlite, itemId, "text", payload.markdown.slice(0, 24_000))
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
        // Dispatch owns a response before harness initialization begins. Persist
        // its waiting row atomically with the user echo so a history refresh can
        // never observe the accepted prompt as a finished, user-only transcript.
        if (conversation.role === "user" && payload.startsTurn === true) {
          ensureAssistantChatItem(sqlite, sessionId, event.created_at)
        }
      } else if (conversation?.role === "assistant") {
        itemId = ensureAssistantChatItem(sqlite, sessionId, event.created_at)
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
            upsertChatPart(sqlite, itemId, "plan", payload.markdown.slice(0, 24_000))
            // A (re)proposed plan closes the planning section; any earlier
            // resume belonged to the plan it replaces.
            sqlite
              .prepare(
                "update chat_items set plan_proposed_at = ?, plan_resumed_at = null where id = ?"
              )
              .run(event.created_at, itemId)
          } else if (update === "question_resolved") {
            // Answering the plan — approve or keep planning — resumes the
            // same turn. The first answer after a proposal starts the
            // section below the plan; the wait for the user belongs to
            // neither section.
            sqlite
              .prepare(
                `update chat_items set plan_resumed_at = ?
                 where id = ? and plan_proposed_at is not null and plan_resumed_at is null`
              )
              .run(event.created_at, itemId)
          }
          if (toolId !== undefined) setChatRoute(sqlite, sessionId, `tool:${toolId}`, itemId)
          const image =
            payload.kind === "image_generation" && payload.status === "completed"
              ? jsonRecord(jsonRecord(payload.rawOutput)?.attachment)
              : undefined
          if (image !== undefined && typeof image.fileId === "string" && parent === undefined) {
            const current = sqlite
              .prepare("select attachments from chat_items where id = ?")
              .get(itemId) as { attachments: string | null }
            const attachments = [...(parseAttachments(current.attachments) ?? [])]
            if (!attachments.some((file) => file.fileId === image.fileId))
              attachments.push(image as unknown as AttachmentRef)
            sqlite
              .prepare("update chat_items set attachments = ? where id = ?")
              .run(serializeAttachments(attachments), itemId)
          }
        }
      }
    }
  } else if (
    event.kind === "session.error" ||
    (event.kind === "session.updated" &&
      (payload.turnState === "ended" || typeof payload.stopReason === "string"))
  ) {
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
    itemId =
      (turnId === undefined ? undefined : chatRoute(sqlite, sessionId, `turn:${turnId}`)) ??
      currentItemId ??
      latestStreamingItem()
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
        typeof payload.stopKind === "string" ? payload.stopKind : undefined,
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

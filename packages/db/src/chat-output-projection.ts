import type { AttachmentRef } from "@codevisor/api"
import type Database from "better-sqlite3"

import {
  chatRoute,
  createChatItem,
  ensureAssistantChatItem,
  setChatRoute,
  upsertChatPart
} from "./chat-items.js"
import {
  conversationEventPayload,
  hasRenderableWorkedDetail,
  jsonRecord,
  type JsonRecord
} from "./event-payloads.js"
import { parseAttachments, serializeAttachments } from "./row-mappers.js"
import type { SessionEventRow } from "./rows.js"

type Conversation = NonNullable<ReturnType<typeof conversationEventPayload>>

const finalizeAssistantMessage = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  sessionId: string
): string => {
  const itemId = ensureAssistantChatItem(sqlite, sessionId, event.created_at)
  upsertChatPart(sqlite, itemId, "text", (payload.markdown as string).slice(0, 24_000))
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
  return itemId
}

const existingRetryUser = (
  sqlite: Database.Database,
  sessionId: string,
  conversation: Conversation
): { readonly id: string } | undefined => {
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
  return existingUser
}

const projectUserOrSystemConversation = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  sessionId: string,
  conversation: Conversation
): string => {
  const existingUser = existingRetryUser(sqlite, sessionId, conversation)
  const itemId =
    existingUser?.id ??
    createChatItem(sqlite, sessionId, conversation.role, event.created_at, {
      text: conversation.text,
      ...(conversation.messageId === undefined ? {} : { messageId: conversation.messageId }),
      status: "complete",
      ...(conversation.attachments === undefined ? {} : { attachments: conversation.attachments })
    })
  // Dispatch owns a response before harness initialization begins. Persist
  // its waiting row atomically with the user echo so a history refresh can
  // never observe the accepted prompt as a finished, user-only transcript.
  if (conversation.role === "user" && payload.startsTurn === true) {
    ensureAssistantChatItem(sqlite, sessionId, event.created_at)
  }
  return itemId
}

const projectAssistantIdentity = (
  sqlite: Database.Database,
  event: SessionEventRow,
  sessionId: string,
  conversation: Conversation
): string => {
  const itemId = ensureAssistantChatItem(sqlite, sessionId, event.created_at)
  sqlite
    .prepare(
      `update chat_items set message_id = coalesce(message_id, ?), updated_at = ?,
           revision = revision + 1 where id = ?`
    )
    .run(conversation.messageId ?? null, event.created_at, itemId)
  return itemId
}

const projectPlanTiming = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  update: string | undefined,
  itemId: string
): void => {
  if (update === "plan_document" && typeof payload.markdown === "string") {
    upsertChatPart(sqlite, itemId, "plan", payload.markdown.slice(0, 24_000))
    // A (re)proposed plan closes the planning section; any earlier
    // resume belonged to the plan it replaces.
    sqlite
      .prepare("update chat_items set plan_proposed_at = ?, plan_resumed_at = null where id = ?")
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
}

const appendCompletedImage = (
  sqlite: Database.Database,
  payload: JsonRecord,
  itemId: string,
  parent: string | undefined
): void => {
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

const projectWorkedDetail = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  sessionId: string,
  update: string | undefined
): string | undefined => {
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
    const itemId =
      (parent === undefined ? undefined : chatRoute(sqlite, sessionId, `tool:${parent}`)) ??
      (toolId === undefined ? undefined : chatRoute(sqlite, sessionId, `tool:${toolId}`)) ??
      ensureAssistantChatItem(sqlite, sessionId, event.created_at)
    sqlite
      .prepare(
        `update chat_items set has_details = max(has_details, ?), updated_at = ?,
             revision = revision + 1 where id = ?`
      )
      .run(hasRenderableWorkedDetail(payload) ? 1 : 0, event.created_at, itemId)
    projectPlanTiming(sqlite, event, payload, update, itemId)
    if (toolId !== undefined) setChatRoute(sqlite, sessionId, `tool:${toolId}`, itemId)
    appendCompletedImage(sqlite, payload, itemId, parent)
    return itemId
  }
  return undefined
}

export const projectChatOutput = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  sessionId: string
): string | undefined => {
  const update = typeof payload.sessionUpdate === "string" ? payload.sessionUpdate : undefined
  if (update === "assistant_message_finalized" && typeof payload.markdown === "string") {
    return finalizeAssistantMessage(sqlite, event, payload, sessionId)
  } else {
    const conversation = conversationEventPayload(payload)
    if (conversation?.role === "user" || conversation?.role === "system") {
      return projectUserOrSystemConversation(sqlite, event, payload, sessionId, conversation)
    } else if (conversation?.role === "assistant") {
      return projectAssistantIdentity(sqlite, event, sessionId, conversation)
    } else {
      return projectWorkedDetail(sqlite, event, payload, sessionId, update)
    }
  }
}

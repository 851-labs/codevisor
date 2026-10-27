import type { AttachmentRef } from "@codevisor/api"
import type Database from "better-sqlite3"

import {
  chatRoute,
  chatRouteForId,
  chatState,
  createChatItem,
  ensureAssistantChatItem,
  finishAssistantChatItem,
  setChatRoute,
  upsertChatPart
} from "./chat-items.js"
import { idRows } from "./common-rows.js"
import {
  conversationEventPayload,
  hasRenderableWorkedDetail,
  isAttachmentRef,
  isAttachmentRefs,
  jsonRecord,
  type JsonRecord
} from "./event-payloads.js"
import { recordToolFileChanges } from "./file-change-projection.js"
import { parseAttachments, serializeAttachments } from "./row-mappers.js"
import { nullable, rowReader, text } from "./row-reader.js"
import type { SessionEventRow } from "./rows.js"
import { recordTextMedia, recordToolMedia } from "./tool-media-projection.js"
import { splitsWorkedSection } from "./transcript-questions.js"

const attachmentsRows = rowReader({ attachments: nullable(text) })

const turnIdRows = rowReader({ turn_id: nullable(text) })

type Conversation = NonNullable<ReturnType<typeof conversationEventPayload>>

const steeredMessageOwner = (
  sqlite: Database.Database,
  sessionId: string,
  itemId: string,
  messageId: string
): string | undefined => {
  const earlier = chatRoute(sqlite, sessionId, `steered:${itemId}`)
  if (earlier === undefined) return undefined
  if (hasTranscriptEntry(sqlite, earlier, `message::${messageId}`)) return earlier
  return steeredMessageOwner(sqlite, sessionId, earlier, messageId)
}

const assistantItemForMessage = (
  sqlite: Database.Database,
  sessionId: string,
  createdAt: string,
  messageId: unknown
): string => {
  const current = ensureAssistantChatItem(sqlite, sessionId, createdAt)
  if (typeof messageId !== "string") return current
  return steeredMessageOwner(sqlite, sessionId, current, messageId) ?? current
}

const finalizeAssistantMessage = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  markdown: string,
  sessionId: string
): string => {
  const itemId = assistantItemForMessage(sqlite, sessionId, event.created_at, payload.messageId)
  upsertChatPart(sqlite, itemId, "text", markdown.slice(0, 24_000))
  const attachments = isAttachmentRefs(payload.attachments) ? payload.attachments : undefined
  sqlite
    .prepare(chatItemSql.finalizeMessage)
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
): string | undefined => {
  if (conversation.role !== "user" || conversation.messageId === undefined) return undefined
  return userItemForMessage(sqlite, sessionId, conversation.messageId)
}

const projectUserOrSystemConversation = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  sessionId: string,
  conversation: Conversation
): string => {
  const existingUser = existingRetryUser(sqlite, sessionId, conversation)
  const steeredItem = closeAssistantSectionForSteer(
    sqlite,
    event,
    payload,
    sessionId,
    conversation,
    existingUser
  )
  const itemId =
    existingUser ??
    createChatItem(sqlite, sessionId, conversation.role, event.created_at, {
      text: conversation.text,
      ...(conversation.messageId === undefined ? {} : { messageId: conversation.messageId }),
      status: "complete",
      ...(conversation.attachments === undefined ? {} : { attachments: conversation.attachments }),
      ...(conversation.origin === undefined ? {} : { origin: conversation.origin }),
      ...(conversation.attribution === undefined ? {} : { attribution: conversation.attribution })
    })
  if (steeredItem !== undefined) {
    continueTurnInNewSection(sqlite, event, sessionId, steeredItem)
  } else if (conversation.role === "user" && payload.startsTurn === true) {
    ensureAssistantChatItem(sqlite, sessionId, event.created_at)
  }
  return itemId
}

const closeAssistantSectionForSteer = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  sessionId: string,
  conversation: Conversation,
  existingUser: string | undefined
): string | undefined => {
  if (existingUser === undefined && conversation.role === "user" && payload.startsTurn !== true) {
    return closeAssistantSection(sqlite, event, sessionId)
  }
  return undefined
}

const closeAssistantSection = (
  sqlite: Database.Database,
  event: SessionEventRow,
  sessionId: string
): string | undefined => {
  const current = chatState(sqlite, sessionId).current_item_id
  if (current === null) return undefined
  finishAssistantChatItem(sqlite, sessionId, current, event.created_at)
  return current
}

const continueTurnInNewSection = (
  sqlite: Database.Database,
  event: SessionEventRow,
  sessionId: string,
  closedItem: string
): void => {
  const turnId = chatItemTurnId(sqlite, closedItem)
  sqlite.prepare(chatItemSql.clearTurnId).run(closedItem)
  const itemId = createChatItem(sqlite, sessionId, "assistant", event.created_at, {
    status: "streaming",
    startedAt: event.created_at,
    ...(turnId === null ? {} : { turnId })
  })
  sqlite.prepare(moveTurnRoutesSql).run(itemId, sessionId, closedItem)
  setChatRoute(sqlite, sessionId, `steered:${itemId}`, closedItem)
}

const projectQuestionSection = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  sessionId: string,
  update: string | undefined,
  itemId: string
): void => {
  if (typeof payload.questionId !== "string" || !splitsWorkedSection(payload)) return

  const isCurrent = chatState(sqlite, sessionId).current_item_id === itemId
  if (update === "question") {
    setChatRoute(sqlite, sessionId, `question:${payload.questionId}`, itemId)
    if (isCurrent) finishAssistantChatItem(sqlite, sessionId, itemId, event.created_at)
  } else if (update === "question_resolved" && isCurrent) {
    continueTurnInNewSection(sqlite, event, sessionId, itemId)
  }
}

const projectAssistantIdentity = (
  sqlite: Database.Database,
  event: SessionEventRow,
  sessionId: string,
  conversation: Conversation
): string => {
  const itemId = assistantItemForMessage(
    sqlite,
    sessionId,
    event.created_at,
    conversation.messageId
  )
  sqlite
    .prepare(chatItemSql.identifyAssistant)
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
    sqlite.prepare(chatItemSql.proposePlan).run(event.created_at, itemId)
  } else if (update === "question_resolved") {
    sqlite.prepare(chatItemSql.resumePlan).run(event.created_at, itemId)
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
  if (isAttachmentRef(image) && parent === undefined) {
    const attachments = [...(chatItemAttachments(sqlite, itemId) ?? [])]
    if (!attachments.some((file) => file.fileId === image.fileId)) attachments.push(image)
    sqlite.prepare(chatItemSql.setAttachments).run(serializeAttachments(attachments), itemId)
  }
}

const resolvedQuestionOwner = (
  sqlite: Database.Database,
  sessionId: string,
  update: string,
  payload: JsonRecord
): string | undefined => {
  if (update === "question_resolved" && typeof payload.questionId === "string") {
    return chatRoute(sqlite, sessionId, `question:${payload.questionId}`)
  }
  return undefined
}

const projectWorkedDetail = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  sessionId: string,
  update: string | undefined
): string | undefined => {
  const rendersInAssistantTurn =
    hasRenderableWorkedDetail(payload) ||
    (update === "plan_document" && typeof payload.markdown === "string")
  if (update !== undefined && rendersInAssistantTurn) {
    const parent =
      typeof payload.parentToolCallId === "string" ? payload.parentToolCallId : undefined
    const toolId = typeof payload.toolCallId === "string" ? payload.toolCallId : undefined
    const questionOwner = resolvedQuestionOwner(sqlite, sessionId, update, payload)
    const itemId =
      questionOwner ??
      chatRouteForId(sqlite, sessionId, "tool", parent) ??
      chatRouteForId(sqlite, sessionId, "tool", toolId) ??
      assistantItemForMessage(sqlite, sessionId, event.created_at, payload.messageId)
    sqlite
      .prepare(chatItemSql.markDetails)
      .run(hasRenderableWorkedDetail(payload) ? 1 : 0, event.created_at, itemId)
    projectPlanTiming(sqlite, event, payload, update, itemId)
    if (toolId !== undefined) setChatRoute(sqlite, sessionId, `tool:${toolId}`, itemId)
    appendCompletedImage(sqlite, payload, itemId, parent)
    recordToolMedia(sqlite, event, payload, itemId)
    recordToolFileChanges(sqlite, event, payload, itemId)
    projectQuestionSection(sqlite, event, payload, sessionId, update, itemId)
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
    return finalizeAssistantMessage(sqlite, event, payload, payload.markdown, sessionId)
  } else if (update === "assistant_text_rewritten") {
    return rewrittenTextItem(sqlite, event, payload, sessionId)
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

const rewrittenTextItem = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  sessionId: string
): string | undefined => {
  if (typeof payload.itemId !== "string") return undefined
  const itemId = idRows.maybe(
    sqlite.prepare(chatItemSql.inSession).get(payload.itemId, sessionId)
  )?.id
  if (itemId !== undefined) recordTextMedia(sqlite, event, payload, itemId)
  return itemId
}

const hasTranscriptEntry = (sqlite: Database.Database, itemId: string, key: string): boolean =>
  sqlite.prepare(transcriptEntryExistsSql).get(itemId, key) !== undefined

const userItemForMessage = (
  sqlite: Database.Database,
  sessionId: string,
  messageId: string
): string | undefined =>
  idRows.maybe(sqlite.prepare(chatItemSql.userByMessage).get(sessionId, messageId))?.id

const chatItemTurnId = (sqlite: Database.Database, itemId: string): string | null =>
  turnIdRows.one(sqlite.prepare(chatItemSql.turnId).get(itemId)).turn_id

const chatItemAttachments = (
  sqlite: Database.Database,
  itemId: string
): ReadonlyArray<AttachmentRef> | undefined =>
  parseAttachments(
    attachmentsRows.one(sqlite.prepare(chatItemSql.attachments).get(itemId)).attachments
  )

const chatItemSql = {
  inSession: "select id from chat_items where id = ? and session_id = ?",
  finalizeMessage: `update chat_items set attachments = ?, message_id = coalesce(?, message_id),
           updated_at = ?, revision = revision + 1 where id = ?`,
  userByMessage:
    "select id from chat_items where session_id = ? and role = 'user' and message_id = ? limit 1",
  turnId: "select turn_id from chat_items where id = ?",
  clearTurnId: "update chat_items set turn_id = null where id = ?",
  identifyAssistant: `update chat_items set message_id = coalesce(message_id, ?), updated_at = ?,
           revision = revision + 1 where id = ?`,
  proposePlan: "update chat_items set plan_proposed_at = ?, plan_resumed_at = null where id = ?",
  resumePlan: `update chat_items set plan_resumed_at = ?
                 where id = ? and plan_proposed_at is not null and plan_resumed_at is null`,
  attachments: "select attachments from chat_items where id = ?",
  setAttachments: "update chat_items set attachments = ? where id = ?",
  markDetails: `update chat_items set has_details = max(has_details, ?), updated_at = ?,
             revision = revision + 1 where id = ?`
}

const transcriptEntryExistsSql =
  "select 1 from transcript_entries where item_id = ? and entry_key = ?"

const moveTurnRoutesSql = `update chat_item_routes set item_id = ?
         where session_id = ? and item_id = ? and route_key like 'turn:%'`

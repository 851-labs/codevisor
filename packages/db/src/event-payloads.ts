import {
  AttachmentRef,
  BackgroundTask,
  QuestionPayload,
  SessionPlan as SessionPlanSchema,
  type EventKind,
  type SessionPlan
} from "@codevisor/api"
import { Schema } from "effect"

export type JsonRecord = Record<string, unknown>

export const isJsonRecord = (value: unknown): value is JsonRecord =>
  typeof value === "object" && value !== null && !Array.isArray(value)

export const jsonRecord = (value: unknown): JsonRecord | undefined =>
  isJsonRecord(value) ? value : undefined

export const stringField = (record: JsonRecord | undefined, key: string): string | undefined => {
  const value = record?.[key]
  return typeof value === "string" ? value : undefined
}

export const numberField = (record: JsonRecord | undefined, key: string): number | undefined => {
  const value = record?.[key]
  return typeof value === "number" ? value : undefined
}

export const withChatItemId = (payload: unknown, chatItemId: string | null): unknown => {
  const record = jsonRecord(payload)
  return record === undefined || chatItemId === null ? payload : { ...record, chatItemId }
}

export const parseJsonRecord = (raw: string): JsonRecord | undefined => {
  try {
    return jsonRecord(JSON.parse(raw))
  } catch {
    return undefined
  }
}

export const sessionConfigSelectionsFromRaw = (raw: string): Readonly<Record<string, string>> => {
  const record = parseJsonRecord(raw)
  if (record === undefined) return {}
  return Object.fromEntries(
    Object.entries(record).filter(
      (entry): entry is [string, string] => typeof entry[1] === "string"
    )
  )
}

export const AttachmentRefs = Schema.Array(AttachmentRef)

export const isAttachmentRef = Schema.is(AttachmentRef)

export const isAttachmentRefs = Schema.is(AttachmentRefs)

const isQuestionPayload = Schema.is(QuestionPayload)

const isBackgroundTask = Schema.is(BackgroundTask)

const isUnknownArray = Schema.is(Schema.Array(Schema.Unknown))

export const pendingQuestionFromRaw = (raw: string | null): QuestionPayload | undefined => {
  if (raw === null) return undefined
  const parsed: unknown = JSON.parse(raw)
  return isQuestionPayload(parsed) ? parsed : undefined
}

export const backgroundTasksFromRaw = (raw: string): ReadonlyArray<BackgroundTask> => {
  const parsed: unknown = JSON.parse(raw)
  return isUnknownArray(parsed) ? parsed.filter(isBackgroundTask) : []
}

export const sessionPlanFromPayload = (payload: JsonRecord): SessionPlan | undefined => {
  try {
    return Schema.decodeUnknownSync(SessionPlanSchema)({ entries: payload.entries })
  } catch {
    return undefined
  }
}

export const sessionPlanFromRaw = (raw: string | null): SessionPlan | undefined => {
  if (raw === null) return undefined
  const payload = parseJsonRecord(raw)
  return payload === undefined ? undefined : sessionPlanFromPayload(payload)
}

export const payloadText = (payload: JsonRecord): string | undefined => {
  if (typeof payload.text === "string") {
    return payload.text
  }
  const content = jsonRecord(payload.content)
  return content?.type === "text" && typeof content.text === "string" ? content.text : undefined
}

export const payloadMarkdown = (payload: JsonRecord): string | undefined =>
  typeof payload.markdown === "string" ? payload.markdown : undefined

export const hasRenderableWorkedDetail = (payload: JsonRecord): boolean => {
  const update = typeof payload.sessionUpdate === "string" ? payload.sessionUpdate : undefined
  switch (update) {
    case "tool_call":
    case "tool_call_update":
    case "question":
    case "question_resolved":
    case "context_compaction":
      return true
    case "agent_thought_chunk":
      return (payloadText(payload)?.trim().length ?? 0) > 0
    case "agent_message_chunk":
      return (
        (payloadText(payload)?.trim().length ?? 0) > 0 ||
        (payload.phase === "commentary" && typeof payload.messageId === "string")
      )
    default:
      return false
  }
}

export const conversationEventPayload = (
  payload: JsonRecord
):
  | {
      readonly role: "user" | "assistant" | "system"
      readonly text: string
      readonly messageId?: string
      readonly attachments?: ReadonlyArray<AttachmentRef>
      readonly origin?: "event"
    }
  | undefined => {
  const { role, text: directText, messageId, attachments, origin } = payload
  if (
    (role === "user" || role === "assistant" || role === "system") &&
    typeof directText === "string" &&
    (messageId === undefined || typeof messageId === "string") &&
    (attachments === undefined || isAttachmentRefs(attachments))
  ) {
    return {
      role,
      text: directText,
      ...(messageId === undefined ? {} : { messageId }),
      ...(attachments === undefined ? {} : { attachments }),
      ...(origin === "event" ? { origin } : {})
    }
  }
  if (
    typeof payload.sessionUpdate !== "string" ||
    typeof payload.parentToolCallId === "string" ||
    payload.phase === "commentary"
  ) {
    return undefined
  }
  const text = payloadText(payload)
  if (text === undefined) return undefined
  if (payload.sessionUpdate === "user_message_chunk") {
    return {
      role: "user",
      text,
      ...(typeof payload.messageId === "string" ? { messageId: payload.messageId } : {})
    }
  }
  if (payload.sessionUpdate === "agent_message_chunk") {
    return {
      role: "assistant",
      text,
      ...(typeof payload.messageId === "string" ? { messageId: payload.messageId } : {})
    }
  }
  return undefined
}

export const isRenderableWorkedEvent = (payload: JsonRecord): boolean =>
  conversationEventPayload(payload) === undefined && hasRenderableWorkedDetail(payload)

export const isSessionShellEvent = (kind: EventKind, payload: unknown): boolean => {
  if (
    kind === "session.created" ||
    kind === "session.archived" ||
    kind === "session.deleted" ||
    kind === "session.attention.updated"
  ) {
    return true
  }
  if (kind !== "session.updated") return false
  const value = jsonRecord(payload)
  return typeof value?.id === "string" && typeof value.projectId === "string"
}

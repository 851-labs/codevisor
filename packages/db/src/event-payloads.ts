import type { AttachmentRef, BackgroundTask, EventKind, QuestionPayload } from "@codevisor/api"

export type JsonRecord = Record<string, unknown>

export const jsonRecord = (value: unknown): JsonRecord | undefined =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as JsonRecord)
    : undefined

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

export const pendingQuestionFromRaw = (raw: string | null): QuestionPayload | undefined =>
  raw === null ? undefined : (JSON.parse(raw) as QuestionPayload)

export const backgroundTasksFromRaw = (raw: string): ReadonlyArray<BackgroundTask> =>
  JSON.parse(raw) as ReadonlyArray<BackgroundTask>

export const payloadText = (payload: JsonRecord): string | undefined => {
  if (typeof payload.text === "string") {
    return payload.text
  }
  const content = jsonRecord(payload.content)
  return content?.type === "text" && typeof content.text === "string" ? content.text : undefined
}

/** Whether replaying this non-answer update can produce visible assistant-turn
 * detail. Transport/config updates and empty thought chunks must not create an
 * otherwise empty assistant item. */
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
      // A zero-length commentary chunk can retroactively classify the earlier
      // text span with the same message id as work rather than final output.
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
    }
  | undefined => {
  const role = payload.role
  const direct =
    (role === "user" || role === "assistant" || role === "system") &&
    typeof payload.text === "string" &&
    (payload.messageId === undefined || typeof payload.messageId === "string") &&
    (payload.attachments === undefined || Array.isArray(payload.attachments))
  if (direct) {
    return {
      role,
      text: payload.text as string,
      ...(typeof payload.messageId === "string" ? { messageId: payload.messageId } : {}),
      ...(Array.isArray(payload.attachments)
        ? { attachments: payload.attachments as ReadonlyArray<AttachmentRef> }
        : {})
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
  // Metadata updates carry the full SessionSummary. Turn/config/stream state
  // remains exclusively in the session log.
  return typeof value?.id === "string" && typeof value.projectId === "string"
}

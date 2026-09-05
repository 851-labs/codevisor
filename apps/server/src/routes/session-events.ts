import type { RuntimeEvent, RuntimeEventSink } from "@codevisor/agent-runtime"
import type { AttachmentRef } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import {
  appendAndPublish,
  run,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { promoteAssistantArtifacts } from "./assistant-artifacts.js"
import { persistGeneratedImage } from "./generated-images.js"

/// The standing per-session sink: every runtime event — in-turn or
/// agent-initiated — is persisted and fanned out here. User echoes are
/// filtered because the server materializes its own copy when a prompt is
/// accepted.
export const sessionEventSink =
  (
    services: CodevisorServerServices,
    fanout: EventFanout,
    serverId: string,
    sessionId: string
  ): RuntimeEventSink =>
  (event) => {
    if (isUserRuntimeEvent(event)) {
      return
    }
    if (event.kind === "session.authRequired") {
      return (async () => {
        const session = await run(services.db.getSessionSummary(sessionId))
        const detail =
          isRecord(event.payload) && typeof event.payload.detail === "string"
            ? event.payload.detail
            : undefined
        /* v8 ignore next -- sessions with and without pinned accounts are integration-tested. */
        if (session?.harnessAccountId !== undefined) {
          await services.auth?.markAccountExpired(session.harnessAccountId, detail)
        }
        await materializeRuntimeEvent(services.db, fanout, serverId, event, sessionId)
      })()
    }
    const payload = objectPayload(event.payload)
    if (event.kind === "session.output" && payload.kind === "image_generation") {
      return persistGeneratedImage(services, event).then((persisted) =>
        materializeRuntimeEvent(services.db, fanout, serverId, persisted, sessionId)
      )
    }
    if (event.kind === "session.updated" && payload.turnState === "ended") {
      return (async () => {
        await services.mcp?.finishTurn(sessionId).catch((cause: unknown) => {
          console.error(
            `Browser tab cleanup failed for ${sessionId}: ${cause instanceof Error ? cause.message : String(cause)}`
          )
        })
        // Attachments the reply embeds must be durable before the turn closes,
        // so the finalized item and the turn-end event land in that order.
        await promoteAssistantArtifacts(services, fanout, serverId, sessionId).catch(
          (cause: unknown) => {
            console.error(
              `Assistant artifact promotion failed for ${sessionId}: ${cause instanceof Error ? cause.message : String(cause)}`
            )
          }
        )
        await materializeRuntimeEvent(services.db, fanout, serverId, event, sessionId)
      })()
    }
    return materializeRuntimeEvent(services.db, fanout, serverId, event, sessionId)
  }

export const materializeRuntimeEvent = async (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  serverId: string,
  event: RuntimeEvent,
  subjectId: string
): Promise<void> => {
  const payload = objectPayload(event.payload)
  const harnessTitle =
    event.kind === "session.updated" &&
    payload.sessionUpdate === "session_info_update" &&
    typeof payload.title === "string"
      ? payload.title.trim()
      : undefined
  if (harnessTitle !== undefined && harnessTitle.length > 0) {
    const updated = await run(db.updateSessionTitleFromHarness(subjectId, harnessTitle))
    if (updated !== undefined) {
      await appendAndPublish(db, fanout, "session.updated", subjectId, updated)
    }
    return
  }
  // appendEvent atomically persists the session event and updates the
  // canonical semantic chat rows. There is deliberately no second legacy
  // conversation write here: a crash can no longer split the two stores.
  await appendAndPublish(db, fanout, event.kind, subjectId, {
    ...payload,
    serverId
  })
}

const conversationRoles = new Set(["user", "assistant", "system"])

const isConversationPayload = (
  payload: unknown
): payload is {
  readonly role: "user" | "assistant" | "system"
  readonly text: string
  readonly messageId?: string
  readonly attachments?: ReadonlyArray<AttachmentRef>
} =>
  typeof payload === "object" &&
  payload !== null &&
  "role" in payload &&
  "text" in payload &&
  conversationRoles.has(String(payload.role)) &&
  typeof payload.text === "string" &&
  (!("messageId" in payload) || typeof payload.messageId === "string") &&
  (!("attachments" in payload) || Array.isArray(payload.attachments))

const conversationPayload = (
  payload: unknown
):
  | {
      readonly role: "user" | "assistant" | "system"
      readonly text: string
      readonly messageId?: string
      readonly attachments?: ReadonlyArray<AttachmentRef>
    }
  | undefined => {
  if (isConversationPayload(payload)) {
    return payload
  }
  if (!isRecord(payload) || typeof payload.sessionUpdate !== "string") {
    return undefined
  }
  // Subagent-attributed chunks stay out of the text conversation snapshot;
  // clients rebuild nested subagent transcripts from the raw event log.
  if (typeof payload.parentToolCallId === "string") {
    return undefined
  }
  const text = textFromRawContent(payload.content)
  if (text === undefined) {
    return undefined
  }
  switch (payload.sessionUpdate) {
    case "user_message_chunk":
      return {
        role: "user",
        text,
        ...(typeof payload.messageId === "string" ? { messageId: payload.messageId } : {})
      }
    case "agent_message_chunk":
      return {
        role: "assistant",
        text,
        ...(typeof payload.messageId === "string" ? { messageId: payload.messageId } : {})
      }
    default:
      return undefined
  }
}

const isUserRuntimeEvent = (event: RuntimeEvent): boolean =>
  conversationPayload(event.payload)?.role === "user"

const textFromRawContent = (content: unknown): string | undefined =>
  isRecord(content) && content.type === "text" && typeof content.text === "string"
    ? content.text
    : undefined

const objectPayload = (payload: unknown): Record<string, unknown> =>
  isRecord(payload) ? payload : { value: payload }

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

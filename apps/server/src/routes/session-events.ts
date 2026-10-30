import {
  usageLimitsObservation,
  type RuntimeEvent,
  type RuntimeEventSink,
  type UsageLimitsObservation
} from "@codevisor/agent-runtime"
import type { AttachmentRef } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"

import { usageLimitsKey } from "../infra/usage-limits-cache.js"
import {
  appendAndPublish,
  run,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { parksQuestionForUpdate, withUpdatePauseStop } from "../update-pauses.js"
import { promoteAssistantArtifacts, withClosedTextCapture } from "./assistant-artifacts.js"
import { ExecutionAnnotator } from "./execution-annotator.js"
import { persistGeneratedImage } from "./generated-images.js"
import { echoesHiddenPrompt } from "./hidden-prompt-titles.js"
import { persistToolImages, toolImageCandidates } from "./tool-images.js"

const executionAnnotators = new WeakMap<CodevisorServerServices, ExecutionAnnotator>()

const executionAnnotator = (services: CodevisorServerServices): ExecutionAnnotator => {
  let annotator = executionAnnotators.get(services)
  if (annotator === undefined) {
    annotator = new ExecutionAnnotator()
    executionAnnotators.set(services, annotator)
  }
  return annotator
}

const observeUsageLimits = async (
  services: CodevisorServerServices,
  sessionId: string,
  observation: UsageLimitsObservation
): Promise<void> => {
  const cache = services.usageLimits
  if (cache === undefined) return
  const session = await run(services.db.getSessionSummary(sessionId))
  cache.observe(
    usageLimitsKey(session.harnessId, session.harnessAccountId),
    observation.limits,
    observation.partial
  )
}

export const sessionEventSink =
  (
    services: CodevisorServerServices,
    fanout: EventFanout,
    serverId: string,
    sessionId: string
  ): RuntimeEventSink =>
  (event) => {
    if (isUserRuntimeEvent(event)) {
      return undefined
    }
    const observation =
      event.kind === "session.updated" ? usageLimitsObservation(event.payload) : undefined
    if (observation !== undefined) {
      return observeUsageLimits(services, sessionId, observation).catch(() => undefined)
    }
    const payload = objectPayload(event.payload)
    if (event.kind === "session.output" && parksQuestionForUpdate(services, sessionId, payload)) {
      return undefined
    }
    if (event.kind === "session.output") {
      return withClosedTextCapture(services, fanout, serverId, sessionId, () =>
        materializeOutput(services, fanout, serverId, sessionId, event, payload)
      )
    }
    if (event.kind === "session.updated" && payload.turnState === "ended") {
      executionAnnotator(services).endSession(sessionId)
      return (async () => {
        await services.mcp?.finishTurn(sessionId).catch((cause: unknown) => {
          console.error(
            `Browser tab cleanup failed for ${sessionId}: ${cause instanceof Error ? cause.message : String(cause)}`
          )
        })
        await promoteAssistantArtifacts(services, fanout, serverId, sessionId).catch(
          (cause: unknown) => {
            console.error(
              `Assistant artifact promotion failed for ${sessionId}: ${cause instanceof Error ? cause.message : String(cause)}`
            )
          }
        )
        if (payload.stopKind === "authRequired") {
          const session = await run(services.db.getSessionSummary(sessionId))
          if (session.harnessAccountId !== undefined) {
            await services.auth?.markAccountExpired(
              session.harnessAccountId,
              typeof payload.stopDetail === "string" ? payload.stopDetail : undefined
            )
          }
        }
        const ended = withUpdatePauseStop(services, sessionId, event, payload)
        await materializeRuntimeEvent(services.db, fanout, serverId, ended, sessionId)
      })()
    }
    return materializeRuntimeEvent(services.db, fanout, serverId, event, sessionId)
  }

const materializeOutput = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  event: RuntimeEvent,
  payload: Readonly<Record<string, unknown>>
): Promise<void> => {
  if (payload.kind === "image_generation") {
    const persisted = await persistGeneratedImage(services, event)
    return materializeRuntimeEvent(services.db, fanout, serverId, persisted, sessionId)
  }

  let output = event
  const images = toolImageCandidates(payload)
  if (images.size > 0) output = await persistToolImages(services, event, payload, images)
  for (const next of executionAnnotator(services).annotate(sessionId, output)) {
    await materializeRuntimeEvent(services.db, fanout, serverId, next, sessionId)
  }
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
    if (await echoesHiddenPrompt(db, subjectId, harnessTitle)) return
    const updated = await run(db.updateSessionTitleFromHarness(subjectId, harnessTitle))
    if (updated !== undefined) {
      await appendAndPublish(db, fanout, "session.updated", subjectId, updated)
    }
    return
  }
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

import type * as acp from "@agentclientprotocol/sdk"
import { runtimeEventFromNotification } from "@codevisor/adapter-acp"
import type { RuntimeEvent } from "@codevisor/agent-runtime"

import { record, type JsonRecord } from "./record.js"

interface GrokResponseState {
  readonly messageId: string
  hasText: boolean
  commentary: boolean
  final: boolean
}

interface GrokSessionStreamState {
  promptId?: string
  responseOrdinal: number
  current: GrokResponseState | undefined
  last: GrokResponseState | undefined
}

const extensionNotification = (
  params: unknown
): { readonly sessionId: string; readonly update: Record<string, unknown> } | undefined => {
  const outer = record(params)
  if (outer === undefined) return undefined
  const unwrapped = typeof outer.method === "string" ? record(outer.params) : outer
  if (unwrapped === undefined || typeof unwrapped.sessionId !== "string") return undefined
  const update = record(unwrapped.update)
  return update === undefined ? undefined : { sessionId: unwrapped.sessionId, update }
}

const notificationPromptId = (notification: acp.SessionNotification): string | undefined => {
  const meta =
    record(notification._meta) ?? ("meta" in notification ? record(notification.meta) : undefined)
  return typeof meta?.promptId === "string" ? meta.promptId : undefined
}

const contentText = (update: Readonly<JsonRecord>): string => {
  const content = record(update.content)
  return content?.type === "text" && typeof content.text === "string" ? content.text : ""
}

const phaseCorrection = (
  sessionId: string,
  messageId: string,
  phase: "commentary" | "final"
): RuntimeEvent => ({
  kind: "session.output",
  subjectId: sessionId,
  payload: {
    content: { text: "", type: "text" },
    messageId,
    phase,
    sessionUpdate: "agent_message_chunk"
  }
})

export class GrokStreamNormalizer {
  private readonly sessions = new Map<string, GrokSessionStreamState>()
  private readonly fallbackOrdinals = new Map<string, number>()

  mapSessionNotification(notification: acp.SessionNotification): ReadonlyArray<RuntimeEvent> {
    const sessionId = notification.sessionId
    const update = notification.update
    const fields: Readonly<JsonRecord> = update
    const promptId = notificationPromptId(notification)
    if (update.sessionUpdate === "user_message_chunk") {
      const completed = this.completeTurn(sessionId)
      this.adoptPrompt(this.state(sessionId), promptId)
      return [...completed, runtimeEventFromNotification(notification)]
    }
    const state = this.state(sessionId)
    this.adoptPrompt(state, promptId)
    switch (update.sessionUpdate) {
      case "agent_message_chunk":
      case "agent_thought_chunk": {
        const suppliedId = typeof update.messageId === "string" ? update.messageId : undefined
        const response = this.ensureResponse(sessionId, state, suppliedId)
        if (update.sessionUpdate === "agent_message_chunk" && contentText(fields).length > 0) {
          response.hasText = true
        }
        if (fields.phase === "commentary") response.commentary = true
        if (fields.phase === "final") response.final = true
        const normalized: acp.SessionNotification = {
          ...notification,
          update: { ...update, messageId: response.messageId }
        }
        return [runtimeEventFromNotification(normalized)]
      }
      case "tool_call": {
        const correction = this.demoteVisibleResponse(sessionId, state)
        this.closeCurrent(state)
        return [
          ...(correction === undefined ? [] : [correction]),
          runtimeEventFromNotification(notification)
        ]
      }
      default:
        return [runtimeEventFromNotification(notification)]
    }
  }

  mapExtensionNotification(params: unknown): ReadonlyArray<RuntimeEvent> {
    const notification = extensionNotification(params)
    if (notification === undefined) return []
    const state = this.state(notification.sessionId)
    switch (notification.update.sessionUpdate) {
      case "response_started": {
        const messageId =
          typeof notification.update.message_id === "string"
            ? notification.update.message_id
            : undefined
        this.startResponse(notification.sessionId, state, messageId)
        return []
      }
      case "tool_call_delta_chunk": {
        const correction = this.demoteVisibleResponse(notification.sessionId, state)
        return correction === undefined ? [] : [correction]
      }
      case "response_completed":
        this.closeCurrent(state)
        return []
      case "turn_completed": {
        const promptId =
          typeof notification.update.prompt_id === "string"
            ? notification.update.prompt_id
            : undefined
        this.adoptPrompt(state, promptId)
        return this.completeTurn(notification.sessionId)
      }
      default:
        return []
    }
  }

  completeTurn(sessionId: string): ReadonlyArray<RuntimeEvent> {
    const state = this.sessions.get(sessionId)
    if (state === undefined) return []
    const response = state.current ?? state.last
    const correction =
      response !== undefined && response.hasText && !response.commentary && !response.final
        ? phaseCorrection(sessionId, response.messageId, "final")
        : undefined
    if (response !== undefined && correction !== undefined) response.final = true
    this.sessions.delete(sessionId)
    return correction === undefined ? [] : [correction]
  }

  cancelTurn(sessionId: string): void {
    this.sessions.delete(sessionId)
  }

  private state(sessionId: string): GrokSessionStreamState {
    const existing = this.sessions.get(sessionId)
    if (existing !== undefined) return existing
    const created: GrokSessionStreamState = {
      current: undefined,
      last: undefined,
      responseOrdinal: 0
    }
    this.sessions.set(sessionId, created)
    return created
  }

  private adoptPrompt(state: GrokSessionStreamState, promptId: string | undefined): void {
    if (promptId === undefined || state.promptId === promptId) return
    if (state.promptId === undefined) {
      state.promptId = promptId
      return
    }
    state.promptId = promptId
    state.responseOrdinal = 0
    state.current = undefined
    state.last = undefined
  }

  private ensureResponse(
    sessionId: string,
    state: GrokSessionStreamState,
    suppliedId: string | undefined
  ): GrokResponseState {
    if (
      state.current !== undefined &&
      (suppliedId === undefined || suppliedId === state.current.messageId)
    ) {
      return state.current
    }
    return this.startResponse(sessionId, state, suppliedId)
  }

  private startResponse(
    sessionId: string,
    state: GrokSessionStreamState,
    suppliedId: string | undefined
  ): GrokResponseState {
    this.closeCurrent(state)
    const ordinal = state.responseOrdinal
    state.responseOrdinal += 1
    const messageId = suppliedId ?? this.syntheticMessageId(sessionId, state.promptId, ordinal)
    const response: GrokResponseState = {
      commentary: false,
      final: false,
      hasText: false,
      messageId
    }
    state.current = response
    return response
  }

  private syntheticMessageId(
    sessionId: string,
    promptId: string | undefined,
    responseOrdinal: number
  ): string {
    if (promptId !== undefined) return `grok:${promptId}:${responseOrdinal}`
    const fallback = this.fallbackOrdinals.get(sessionId) ?? 0
    this.fallbackOrdinals.set(sessionId, fallback + 1)
    return `grok:${sessionId}:${fallback}`
  }

  private closeCurrent(state: GrokSessionStreamState): void {
    if (state.current === undefined) return
    state.last = state.current
    state.current = undefined
  }

  private demoteVisibleResponse(
    sessionId: string,
    state: GrokSessionStreamState
  ): RuntimeEvent | undefined {
    const response = state.current ?? state.last
    if (response === undefined || !response.hasText || response.commentary) return undefined
    response.commentary = true
    response.final = false
    return phaseCorrection(sessionId, response.messageId, "commentary")
  }
}

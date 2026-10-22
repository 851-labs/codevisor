import type * as acp from "@agentclientprotocol/sdk"
import { runtimeEventFromNotification } from "@codevisor/adapter-acp"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { isPlainRecord } from "@codevisor/api"

import {
  couldBeCursorTerminalError,
  parseCursorTerminalError,
  type CursorTerminalError
} from "./errors.js"

type CursorMessageChunk = Extract<
  acp.SessionUpdate,
  { sessionUpdate: "agent_message_chunk" | "agent_thought_chunk" }
>

type CursorAgentChunk = Extract<CursorMessageChunk, { sessionUpdate: "agent_message_chunk" }>

interface CursorMessageState {
  readonly messageId: string
  hasText: boolean
  commentary: boolean
  final: boolean
}

interface CursorTurnState {
  readonly turnOrdinal: number
  segmentOrdinal: number
  current: CursorMessageState | undefined
  last: CursorMessageState | undefined
  pendingAgentText: CursorPendingAgentText | undefined
  suppressUserEcho: boolean
}

interface CursorPendingAgentText {
  notification: acp.SessionNotification
  update: CursorAgentChunk
  text: string
}

export interface CursorPromptLegResult {
  readonly events: ReadonlyArray<RuntimeEvent>
  readonly terminalError?: CursorTerminalError
}

const holdsCursorTerminalError = (state: CursorTurnState): boolean =>
  state.pendingAgentText !== undefined &&
  parseCursorTerminalError(state.pendingAgentText.text) !== undefined

const contentText = (content: unknown): string =>
  isPlainRecord(content) && content.type === "text" && typeof content.text === "string"
    ? content.text
    : ""

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

export class CursorStreamNormalizer {
  private readonly sessions = new Map<string, CursorTurnState>()
  private readonly nextTurnOrdinals = new Map<string, number>()

  startTurn(sessionId: string): ReadonlyArray<RuntimeEvent> {
    const completed = this.completeTurn(sessionId)
    const turnOrdinal = this.nextTurnOrdinals.get(sessionId) ?? 0
    this.nextTurnOrdinals.set(sessionId, turnOrdinal + 1)
    this.sessions.set(sessionId, {
      turnOrdinal,
      segmentOrdinal: 0,
      current: undefined,
      last: undefined,
      pendingAgentText: undefined,
      suppressUserEcho: false
    })
    return completed
  }

  startPrompt(sessionId: string): ReadonlyArray<RuntimeEvent> {
    const completed = this.startTurn(sessionId)
    this.sessions.get(sessionId)!.suppressUserEcho = true
    return completed
  }

  continuePrompt(sessionId: string): void {
    const state = this.state(sessionId)
    state.suppressUserEcho = true
  }

  mapSessionNotification(notification: acp.SessionNotification): ReadonlyArray<RuntimeEvent> {
    const { sessionId, update } = notification
    if (update.sessionUpdate === "user_message_chunk") {
      const active = this.sessions.get(sessionId)
      if (active?.suppressUserEcho === true) return []
      const completed = this.startTurn(sessionId)
      return [...completed, runtimeEventFromNotification(notification)]
    }
    const state = this.state(sessionId)
    state.suppressUserEcho = false
    if (update.sessionUpdate === "agent_message_chunk") {
      const text = contentText(update.content)
      if (state.pendingAgentText !== undefined) {
        state.pendingAgentText = {
          notification,
          update,
          text: state.pendingAgentText.text + text
        }
        if (couldBeCursorTerminalError(state.pendingAgentText.text)) return []
        return this.flushPendingAgentText(sessionId, state)
      }
      if (couldBeCursorTerminalError(text)) {
        state.pendingAgentText = { notification, update, text }
        return []
      }
    }
    let pending: ReadonlyArray<RuntimeEvent> = []
    if (!holdsCursorTerminalError(state)) pending = this.flushPendingAgentText(sessionId, state)
    switch (update.sessionUpdate) {
      case "agent_message_chunk":
      case "agent_thought_chunk": {
        return [...pending, this.mapMessageNotification(notification, update, state)]
      }
      case "tool_call": {
        const correction = this.demoteVisibleMessage(sessionId, state)
        this.closeCurrent(state)
        return [
          ...pending,
          ...(correction === undefined ? [] : [correction]),
          runtimeEventFromNotification(notification)
        ]
      }
      default:
        return [...pending, runtimeEventFromNotification(notification)]
    }
  }

  settlePromptLeg(sessionId: string): CursorPromptLegResult {
    const state = this.sessions.get(sessionId)
    if (state === undefined) return { events: [] }
    state.suppressUserEcho = false
    const candidate = state.pendingAgentText
    if (candidate === undefined) return { events: [] }
    const terminalError = parseCursorTerminalError(candidate.text)
    if (terminalError === undefined) {
      return { events: this.flushPendingAgentText(sessionId, state) }
    }
    state.pendingAgentText = undefined
    return { events: [], terminalError }
  }

  completeTurn(sessionId: string): ReadonlyArray<RuntimeEvent> {
    const state = this.sessions.get(sessionId)
    if (state === undefined) return []
    const pending = this.flushPendingAgentText(sessionId, state)
    const message = state.current ?? state.last
    const correction =
      message !== undefined && message.hasText && !message.commentary && !message.final
        ? phaseCorrection(sessionId, message.messageId, "final")
        : undefined
    this.sessions.delete(sessionId)
    return correction === undefined ? pending : [...pending, correction]
  }

  cancelTurn(sessionId: string): void {
    this.sessions.delete(sessionId)
  }

  private state(sessionId: string): CursorTurnState {
    const existing = this.sessions.get(sessionId)
    if (existing !== undefined) return existing
    this.startTurn(sessionId)
    return this.sessions.get(sessionId)!
  }

  private ensureMessage(
    sessionId: string,
    state: CursorTurnState,
    suppliedId: string | undefined
  ): CursorMessageState {
    if (
      state.current !== undefined &&
      (suppliedId === undefined || suppliedId === state.current.messageId)
    ) {
      return state.current
    }
    this.closeCurrent(state)
    const messageId =
      suppliedId ?? `cursor:${sessionId}:${state.turnOrdinal}:${state.segmentOrdinal}`
    state.segmentOrdinal += 1
    const message: CursorMessageState = {
      messageId,
      hasText: false,
      commentary: false,
      final: false
    }
    state.current = message
    return message
  }

  private mapMessageNotification(
    notification: acp.SessionNotification,
    update: CursorMessageChunk,
    state: CursorTurnState
  ): RuntimeEvent {
    const fields: Record<string, unknown> = update
    const suppliedId = typeof update.messageId === "string" ? update.messageId : undefined
    const message = this.ensureMessage(notification.sessionId, state, suppliedId)
    if (update.sessionUpdate === "agent_message_chunk" && contentText(update.content).length > 0) {
      message.hasText = true
    }
    if (fields.phase === "commentary") message.commentary = true
    if (fields.phase === "final") message.final = true
    return runtimeEventFromNotification({
      ...notification,
      update: { ...update, messageId: message.messageId }
    })
  }

  private flushPendingAgentText(
    sessionId: string,
    state: CursorTurnState
  ): ReadonlyArray<RuntimeEvent> {
    const pending = state.pendingAgentText
    if (pending === undefined) return []
    state.pendingAgentText = undefined
    const content = isPlainRecord(pending.update.content) ? pending.update.content : {}
    const update: CursorAgentChunk = {
      ...pending.update,
      content: { ...content, text: pending.text, type: "text" }
    }
    return [
      this.mapMessageNotification({ ...pending.notification, sessionId, update }, update, state)
    ]
  }

  private closeCurrent(state: CursorTurnState): void {
    if (state.current === undefined) return
    state.last = state.current
    state.current = undefined
  }

  private demoteVisibleMessage(
    sessionId: string,
    state: CursorTurnState
  ): RuntimeEvent | undefined {
    const message = state.current ?? state.last
    if (message === undefined || !message.hasText || message.commentary) return undefined
    message.commentary = true
    message.final = false
    return phaseCorrection(sessionId, message.messageId, "commentary")
  }
}

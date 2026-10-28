import { randomUUID } from "node:crypto"

import { normalizePromptInput, type RuntimeEvent } from "@codevisor/agent-runtime"
import type { TurnStopKind } from "@codevisor/api"

import { claudeContent } from "./attachments.js"
import { deferred } from "./internal.js"
import type { ClaudeSession } from "./session.js"

export interface TurnEnding {
  readonly stopDetail?: string | undefined
  readonly retryable?: boolean | undefined
  readonly stopKind?: TurnStopKind | undefined
  readonly resetsAt?: string | undefined
}

export const refreshClaudeSessionTitle = async (session: ClaudeSession): Promise<void> => {
  try {
    const info = await session.getSessionInfo(session.sdkSessionId, { dir: session.cwd })
    const title = (info?.customTitle ?? info?.summary)?.trim()
    if (title === undefined || title.length === 0 || title === session.lastHarnessTitle) return
    session.lastHarnessTitle = title
    await session.emit({
      kind: "session.updated",
      payload: { sessionUpdate: "session_info_update", title },
      subjectId: session.key
    })
  } catch {}
}

export const finishActiveTurn = (
  session: ClaudeSession,
  stopReason: string,
  ending: TurnEnding = {}
): Promise<void> => {
  const completion = session.turnCompletion
  if (!session.turnActive) return completion?.promise ?? Promise.resolve()

  session.turnActive = false
  session.deferredTaskResult = undefined
  session.awaitingRecoveryResult = false
  session.rootReplyComplete = false
  const wasInterrupted = session.interruptRequested
  const pending = session.pendingPrompt
  session.pendingPrompt = undefined
  const toolEvents: Array<RuntimeEvent> = []
  for (const toolUseId of Array.from(session.openToolCalls)) {
    session.openToolCalls.delete(toolUseId)
    toolEvents.push({
      kind: "session.output",
      payload: {
        sessionUpdate: "tool_call_update",
        status: wasInterrupted ? "cancelled" : "failed",
        toolCallId: toolUseId
      },
      subjectId: session.key
    })
  }
  session.accumulators.clear()
  session.taskToolUses.clear()
  session.skillCalls.clear()
  session.subagentMessageIds.clear()
  session.subagentLastTexts.clear()
  session.forkedCommands.clear()
  session.forkedCommandReplyPending = false

  const ended: RuntimeEvent = {
    kind: "session.updated",
    payload: {
      initiatedBy: session.initiatedBy,
      stopReason,
      ...(ending.stopDetail === undefined ? {} : { stopDetail: ending.stopDetail }),
      ...(ending.stopKind === undefined ? {} : { stopKind: ending.stopKind }),
      ...(ending.resetsAt === undefined ? {} : { resetsAt: ending.resetsAt }),
      ...(ending.retryable === true ? { retryable: true } : {}),
      turnId: session.turnId,
      turnState: "ended"
    },
    subjectId: session.key
  }
  const finalize = async (): Promise<void> => {
    try {
      for (const event of toolEvents) await session.emit(event)
      await session.emit(ended)
      pending?.resolve({ stopReason })
      completion?.resolve()
    } catch (cause) {
      pending?.reject(cause)
      completion?.reject(cause)
      throw cause
    } finally {
      session.interruptRequested = false
    }
    await dispatchNextDeferredPrompt(session)
  }
  void finalize()
  return completion?.promise ?? Promise.resolve()
}

const dispatchNextDeferredPrompt = async (session: ClaudeSession): Promise<void> => {
  if (session.deferredPrompts.length === 0) return
  if (session.retired || session.streamEnded) {
    failDeferredPrompts(session, new Error("Claude runtime was retired"))
    return
  }
  const next = session.deferredPrompts.shift()
  if (next === undefined) return
  session.pendingPrompt = next.pending
  try {
    await ensureTurnStarted(session, "user")
    session.input.push({
      message: { content: claudeContent(normalizePromptInput(next.input)), role: "user" },
      parent_tool_use_id: null,
      session_id: session.sdkSessionId,
      type: "user"
    })
  } catch (cause) {
    if (session.pendingPrompt === next.pending) session.pendingPrompt = undefined
    next.pending.reject(cause)
  }
}

export const failDeferredPrompts = (session: ClaudeSession, cause: unknown): void => {
  const pending = session.deferredPrompts.splice(0)
  for (const prompt of pending) prompt.pending.reject(cause)
}

export const ensureTurnStarted = (
  session: ClaudeSession,
  initiatedBy: "user" | "agent"
): Promise<void> => {
  if (session.turnActive) return Promise.resolve()
  session.turnActive = true
  session.deferredTaskResult = undefined
  session.awaitingRecoveryResult = false
  session.rootReplyComplete = false
  session.turnCompletion = deferred<void>()
  session.turnId = randomUUID()
  session.initiatedBy = initiatedBy
  session.truncationCount = 0
  session.transientRetries = 0
  session.streamRecoveries = 0
  session.lastAssistantError = undefined
  session.lastErrorText = undefined
  session.lastUsageLimitText = undefined
  return session.emit({
    kind: "session.updated",
    payload: { initiatedBy, turnId: session.turnId, turnState: "started" },
    subjectId: session.key
  })
}

export const ensureObservedTurnStarted = (session: ClaudeSession): Promise<void> => {
  if (session.turnActive) return Promise.resolve()
  const hasQueuedUserCommand = session.pendingUserCommands > 0
  if (hasQueuedUserCommand) session.pendingUserCommands -= 1
  return ensureTurnStarted(
    session,
    session.pendingPrompt !== undefined || hasQueuedUserCommand ? "user" : "agent"
  )
}

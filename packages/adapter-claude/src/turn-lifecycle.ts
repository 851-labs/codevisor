import { randomUUID } from "node:crypto"
import { normalizePromptInput, type RuntimeEvent } from "@codevisor/agent-runtime"
import { claudeContent } from "./attachments.js"
import { deferred } from "./internal.js"
import type { ClaudeSession } from "./session.js"

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
  } catch {
    // The first-prompt title remains authoritative when the SDK has not
    // persisted metadata yet or an older Claude build cannot read it.
  }
}

/// Ends the in-flight turn: settles any tool calls that never got a result,
/// clears per-turn accumulators, emits `turnState: ended`, and resolves the
/// awaiting prompt. The single place `turnActive` is cleared. Driven by an SDK
/// `result` (via `handleResult`) and, defensively, by the pump when the SDK
/// stream dies mid-turn — so a wedged stream can never leave the client showing
/// "working" forever.
export const finishActiveTurn = (
  session: ClaudeSession,
  stopReason: string,
  stopDetail?: string | undefined,
  retryable?: boolean | undefined,
  stopKind?: "usageLimit" | undefined
): Promise<void> => {
  const completion = session.turnCompletion
  if (!session.turnActive) return completion?.promise ?? Promise.resolve()

  // Clear the active bit before awaiting persistence. Every competing
  // terminal path now observes the same completion instead of emitting a
  // duplicate turn end.
  session.turnActive = false
  const wasInterrupted = session.interruptRequested
  const pending = session.pendingPrompt
  session.pendingPrompt = undefined
  const toolEvents: Array<RuntimeEvent> = []
  // Anything still open never got a tool_result (interrupt/failure/stream end).
  for (const toolUseId of [...session.openToolCalls]) {
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
  session.subagentMessageIds.clear()

  const ended: RuntimeEvent = {
    kind: "session.updated",
    payload: {
      initiatedBy: session.initiatedBy,
      stopReason,
      // Only present when the turn ended abnormally (error / limit / refusal /
      // truncation we gave up on); the client renders it as a per-turn reason.
      ...(stopDetail === undefined ? {} : { stopDetail }),
      ...(stopKind === undefined ? {} : { stopKind }),
      ...(retryable === true ? { retryable: true } : {}),
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
    // Only after the finished turn's terminal event is durable (and the
    // interrupt flag is reset, so a cancelled turn cannot poison the next
    // one): start the next prompt that was accepted while this turn ran.
    await dispatchNextDeferredPrompt(session)
  }
  void finalize()
  return completion?.promise ?? Promise.resolve()
}

/// Starts the oldest prompt deferred while a turn was active as its own
/// user-initiated turn. A session that can no longer run turns fails the
/// whole backlog instead — every deferred prompt has a server-side drain
/// awaiting it, and a silently dropped promise would wedge that drain (and
/// the user's queue) forever.
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

/// Rejects every deferred prompt (retire/close/stream death). Callers pass
/// the reason the session can no longer run them.
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
  session.turnCompletion = deferred<void>()
  session.turnId = randomUUID()
  session.initiatedBy = initiatedBy
  // Fresh turn: reset the recovery counters (auto-recoveries keep `turnActive`
  // true, so this never fires mid-recovery) and drop any stale error state.
  session.truncationCount = 0
  session.transientRetries = 0
  session.lastAssistantError = undefined
  session.lastErrorText = undefined
  session.lastUsageLimitText = undefined
  return session.emit({
    kind: "session.updated",
    payload: { initiatedBy, turnId: session.turnId, turnState: "started" },
    subjectId: session.key
  })
}

/// Starts a turn discovered from Claude's output. Unlike `prompt()`, slash
/// commands do not hold a deferred prompt, so consume their explicit user
/// marker here before falling back to an autonomous agent continuation.
export const ensureObservedTurnStarted = (session: ClaudeSession): Promise<void> => {
  if (session.turnActive) return Promise.resolve()
  const hasQueuedUserCommand = session.pendingUserCommands > 0
  if (hasQueuedUserCommand) session.pendingUserCommands -= 1
  return ensureTurnStarted(
    session,
    session.pendingPrompt !== undefined || hasQueuedUserCommand ? "user" : "agent"
  )
}

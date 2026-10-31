import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"

import { settleForkedCommands } from "./forked-commands.js"
import { settleGoalOnTurnEnd } from "./goals.js"
import { cancelClaudePendingQuestions } from "./questions.js"
import { classifyResult, MAX_TRANSIENT_RETRIES, type TurnResolution } from "./result-resolution.js"
import { emitResultUsage } from "./result-usage.js"
import type { ClaudeSession } from "./session.js"
import { isStartupFailure, recordStartupFailure } from "./startup-failure.js"
import {
  ensureObservedTurnStarted,
  finishActiveTurn,
  refreshClaudeSessionTitle
} from "./turn-lifecycle.js"

const CONTINUE_PROMPT = "Please continue."

const FORKED_COMMAND_REPLY_PROMPT =
  "The skill the user ran has finished in a subagent, and its report is the command output " +
  "above. Answer the user with its results now, as you would after a subagent reports back. " +
  "Don't run the skill again."

const RESUME_AFTER_INTERRUPTION_PROMPT =
  "Your previous process was interrupted and restarted. Any tool call that was in flight " +
  "did not complete and any background commands it started are gone. Continue the task " +
  "from where it left off, re-running whatever was interrupted."

type ResultMessage = SDKMessage & { type: "result" }

type RetryResolution = Extract<TurnResolution, { kind: "retry" }>

type EndResolution = Extract<TurnResolution, { kind: "end" }>

export const pushResumeAfterInterruptionPrompt = (session: ClaudeSession): void =>
  pushHiddenUserMessage(session, RESUME_AFTER_INTERRUPTION_PROMPT)

export const handleResult = (session: ClaudeSession, message: ResultMessage): void => {
  const isTaskNotification = message.origin?.kind === "task-notification"
  emitResultUsage(session, message)
  if (ignoresTaskNotification(session, isTaskNotification)) {
    if (session.turnActive) {
      session.deferredTaskResult = message
      logDeferredTaskResult(session, message, "deferred")
    }
    return
  }
  if (isStartupFailure(session, message)) {
    recordStartupFailure(session, message)
    return
  }
  session.awaitingRecoveryResult = false
  resolveTurnResult(session, message, isTaskNotification)
}

export const finishDeferredTaskResult = (session: ClaudeSession): void => {
  const message = session.deferredTaskResult
  if (message === undefined || !session.turnActive || session.awaitingRecoveryResult) return
  if (succeeded(message) && !session.rootReplyComplete) return

  logDeferredTaskResult(session, message, "resolved_at_idle")
  resolveTurnResult(session, message, false)
}

const succeeded = (message: ResultMessage): boolean =>
  message.subtype === "success" && !message.is_error

const resolveTurnResult = (
  session: ClaudeSession,
  message: ResultMessage,
  isTaskNotification: boolean
): void => {
  session.deferredTaskResult = undefined
  if (!session.turnActive) void ensureObservedTurnStarted(session)

  const assistantError = session.lastAssistantError
  const resolution = classifyResult(session, message)
  if (turnEndLoggingEnabled()) logTurnEnd(session, message, resolution)
  clearTurnErrors(session)

  if (resolution.kind === "continue") {
    continueTruncatedTurn(session)
    return
  }
  if (resolution.kind === "retry") {
    retryTurn(session, resolution, assistantError)
    return
  }
  if (promptForkedCommandReply(session, resolution)) return

  endTurn(session, message, resolution, isTaskNotification)
}

const logDeferredTaskResult = (
  session: ClaudeSession,
  message: ResultMessage,
  action: "deferred" | "resolved_at_idle"
): void => {
  console.info(
    JSON.stringify({
      event: "claude_task_result",
      sessionId: session.key,
      turnId: session.turnId,
      subtype: message.subtype,
      stopReason: message.stop_reason,
      action
    })
  )
}

const pushHiddenUserMessage = (session: ClaudeSession, content: string): void => {
  session.input.push({
    message: { content, role: "user" },
    parent_tool_use_id: null,
    session_id: session.sdkSessionId,
    type: "user"
  })
}

const pushContinuePrompt = (session: ClaudeSession): void =>
  pushHiddenUserMessage(session, CONTINUE_PROMPT)

const scheduleRecovery = (session: ClaudeSession, delayMs: number): void => {
  session.awaitingRecoveryResult = true
  session.rootReplyComplete = false
  const turnId = session.turnId
  if (delayMs <= 0) {
    pushContinuePrompt(session)
    return
  }
  setTimeout(() => {
    if (session.abort.signal.aborted || !session.turnActive) return
    if (session.turnId !== turnId) return
    pushContinuePrompt(session)
  }, delayMs)
}

const emitRetrying = (
  session: ClaudeSession,
  attempt: number,
  of: number,
  message: string
): void => {
  void session.emit({
    kind: "session.updated",
    payload: {
      retrying: { attempt, message, of },
      turnId: session.turnId
    },
    subjectId: session.key
  })
}

const resolutionOutcome = (resolution: TurnResolution): string => {
  if (resolution.kind === "continue") return "continue"
  if (resolution.kind === "retry") return `retry#${resolution.attempt}(${resolution.delayMs}ms)`
  return `end/${resolution.stopReason}${resolution.stopDetail === undefined ? "" : ` — ${resolution.stopDetail}`}`
}

const logTurnEnd = (
  session: ClaudeSession,
  message: SDKMessage & { type: "result" },
  resolution: TurnResolution
): void => {
  const terminal = (message as { terminal_reason?: unknown }).terminal_reason
  const outcome = resolutionOutcome(resolution)
  console.error(
    `[claude] turn-end subtype=${message.subtype} stop_reason=${message.stop_reason ?? "-"} ` +
      `terminal=${typeof terminal === "string" ? terminal : "-"} lastError=${session.lastAssistantError ?? "-"} ` +
      `trunc=${session.truncationCount} retries=${session.transientRetries} -> ${outcome}`
  )
}

const ignoresTaskNotification = (session: ClaudeSession, isTaskNotification: boolean): boolean =>
  isTaskNotification && (!session.turnActive || session.initiatedBy === "user")

const turnEndLoggingEnabled = (): boolean =>
  process.env.CODEVISOR_DEBUG !== undefined || process.env.HERDMAN_DEBUG !== undefined

const clearTurnErrors = (session: ClaudeSession): void => {
  session.lastAssistantError = undefined
  session.lastUsageLimitText = undefined
  session.latestRateLimitInfo = undefined
}

const continueTruncatedTurn = (session: ClaudeSession): void => {
  session.truncationCount += 1
  scheduleRecovery(session, 0)
}

const retryTurn = (
  session: ClaudeSession,
  resolution: RetryResolution,
  assistantError: string | undefined
): void => {
  session.transientRetries += 1
  emitRetrying(
    session,
    resolution.attempt,
    MAX_TRANSIENT_RETRIES,
    retryMessageForAssistantError(assistantError)
  )
  scheduleRecovery(session, resolution.delayMs)
}

const promptForkedCommandReply = (session: ClaudeSession, resolution: EndResolution): boolean => {
  if (!session.forkedCommandReplyPending) return false
  session.forkedCommandReplyPending = false
  if (!endedCleanly(resolution)) return false

  pushHiddenUserMessage(session, FORKED_COMMAND_REPLY_PROMPT)
  return true
}

const endedCleanly = (resolution: EndResolution): boolean =>
  resolution.stopReason === "end_turn" && resolution.stopDetail === undefined

const endTurn = (
  session: ClaudeSession,
  message: ResultMessage,
  resolution: EndResolution,
  isTaskNotification: boolean
): void => {
  session.lastErrorText = undefined
  void cancelClaudePendingQuestions(session)
  settleForkedCommands(session)
  if (!isTaskNotification) settleGoalOnTurnEnd(session, message)
  void refreshClaudeSessionTitle(session)
  void finishActiveTurn(session, resolution.stopReason, resolution)
}

const retryMessageForAssistantError = (error: string | undefined): string => {
  switch (error) {
    case "overloaded":
      return "Claude is still overloaded, restarting response"
    case "rate_limit":
      return "Claude is temporarily rate limited, restarting response"
    case "server_error":
      return "Claude returned a server error, restarting response"
    default:
      return "Claude is unavailable, restarting response"
  }
}

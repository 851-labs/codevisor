import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"

import { settleForkedCommands } from "./forked-commands.js"
import { settleGoalOnTurnEnd } from "./goals.js"
import { isRecord } from "./internal.js"
import { cancelClaudePendingQuestions } from "./questions.js"
import { classifyResult, MAX_TRANSIENT_RETRIES, type TurnResolution } from "./result-resolution.js"
import type { ClaudeSession } from "./session.js"
import {
  ensureObservedTurnStarted,
  finishActiveTurn,
  refreshClaudeSessionTitle
} from "./turn-lifecycle.js"
import { claudeContextWindowFrom } from "./usage.js"

const CONTINUE_PROMPT = "Please continue."

const FORKED_COMMAND_REPLY_PROMPT =
  "The skill the user ran has finished in a subagent, and its report is the command output " +
  "above. Answer the user with its results now, as you would after a subagent reports back. " +
  "Don't run the skill again."

const RESUME_AFTER_INTERRUPTION_PROMPT =
  "Your previous process was interrupted and restarted. Any tool call that was in flight " +
  "did not complete and any background commands it started are gone. Continue the task " +
  "from where it left off, re-running whatever was interrupted."

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

export const pushResumeAfterInterruptionPrompt = (session: ClaudeSession): void =>
  pushHiddenUserMessage(session, RESUME_AFTER_INTERRUPTION_PROMPT)

const scheduleRecovery = (session: ClaudeSession, delayMs: number): void => {
  if (delayMs <= 0) {
    pushContinuePrompt(session)
    return
  }
  setTimeout(() => {
    if (session.abort.signal.aborted || !session.turnActive) return
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

const logTurnEnd = (
  session: ClaudeSession,
  message: SDKMessage & { type: "result" },
  resolution: TurnResolution
): void => {
  const terminal = (message as { terminal_reason?: unknown }).terminal_reason
  const outcome =
    resolution.kind === "continue"
      ? "continue"
      : resolution.kind === "retry"
        ? `retry#${resolution.attempt}(${resolution.delayMs}ms)`
        : `end/${resolution.stopReason}${resolution.stopDetail === undefined ? "" : ` — ${resolution.stopDetail}`}`
  console.error(
    `[claude] turn-end subtype=${message.subtype} stop_reason=${message.stop_reason ?? "-"} ` +
      `terminal=${typeof terminal === "string" ? terminal : "-"} lastError=${session.lastAssistantError ?? "-"} ` +
      `trunc=${session.truncationCount} retries=${session.transientRetries} -> ${outcome}`
  )
}

export const handleResult = (
  session: ClaudeSession,
  message: SDKMessage & { type: "result" }
): void => {
  const isTaskNotification = message.origin?.kind === "task-notification"
  const raw = message as unknown as Record<string, unknown>
  const usage = isRecord(raw.usage) ? raw.usage : {}
  const token = (key: string): number | undefined =>
    typeof usage[key] === "number" && Number.isFinite(usage[key])
      ? (usage[key] as number)
      : undefined
  const inputTokens = token("input_tokens")
  const cachedInputTokens =
    (token("cache_creation_input_tokens") ?? 0) + (token("cache_read_input_tokens") ?? 0)
  const outputTokens = token("output_tokens")
  const totalTokens =
    inputTokens === undefined && outputTokens === undefined && cachedInputTokens === 0
      ? undefined
      : (inputTokens ?? 0) + cachedInputTokens + (outputTokens ?? 0)
  const costAmount =
    typeof raw.total_cost_usd === "number" && Number.isFinite(raw.total_cost_usd)
      ? raw.total_cost_usd
      : undefined
  const contextUsed = session.latestContextUsage?.used
  const contextSize = claudeContextWindowFrom(
    raw.modelUsage,
    session.latestContextUsage?.model,
    session.currentModel
  )
  if (totalTokens !== undefined || costAmount !== undefined || contextUsed !== undefined) {
    void session.emit({
      kind: "session.updated",
      payload: {
        sessionUpdate: "usage_update",
        ...(contextUsed === undefined ? {} : { used: contextUsed }),
        ...(contextSize === undefined ? {} : { size: contextSize }),
        ...(inputTokens === undefined ? {} : { inputTokens }),
        ...(cachedInputTokens === 0 ? {} : { cachedInputTokens }),
        ...(outputTokens === undefined ? {} : { outputTokens }),
        ...(totalTokens === undefined ? {} : { totalTokens }),
        ...(costAmount === undefined
          ? {}
          : { cost: { amount: costAmount, currency: "USD", kind: "reported" } })
      },
      subjectId: session.key
    })
  }

  if (isTaskNotification && (!session.turnActive || session.initiatedBy === "user")) return
  if (!session.turnActive) void ensureObservedTurnStarted(session)

  const assistantError = session.lastAssistantError
  const resolution = classifyResult(session, message)
  const authFailure =
    assistantError === "authentication_failed" || assistantError === "oauth_org_not_allowed"
  if (process.env.CODEVISOR_DEBUG !== undefined || process.env.HERDMAN_DEBUG !== undefined) {
    logTurnEnd(session, message, resolution)
  }
  session.lastAssistantError = undefined
  session.lastUsageLimitText = undefined
  session.latestRateLimitInfo = undefined

  if (resolution.kind === "continue") {
    session.truncationCount += 1
    scheduleRecovery(session, 0)
    return
  }
  if (resolution.kind === "retry") {
    session.transientRetries += 1
    emitRetrying(
      session,
      resolution.attempt,
      MAX_TRANSIENT_RETRIES,
      retryMessageForAssistantError(assistantError)
    )
    scheduleRecovery(session, resolution.delayMs)
    return
  }
  if (session.forkedCommandReplyPending) {
    session.forkedCommandReplyPending = false
    if (resolution.stopReason === "end_turn" && resolution.stopDetail === undefined) {
      pushHiddenUserMessage(session, FORKED_COMMAND_REPLY_PROMPT)
      return
    }
  }

  session.lastErrorText = undefined
  if (authFailure) {
    void session.emit({
      kind: "session.authRequired",
      subjectId: session.key,
      payload: {
        detail: resolution.kind === "end" ? resolution.stopDetail : "Claude sign-in is required."
      }
    })
  }
  void cancelClaudePendingQuestions(session)
  settleForkedCommands(session)
  if (!isTaskNotification) settleGoalOnTurnEnd(session, message)
  void refreshClaudeSessionTitle(session)
  void finishActiveTurn(
    session,
    resolution.stopReason,
    resolution.stopDetail,
    resolution.retryable,
    resolution.stopKind
  )
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

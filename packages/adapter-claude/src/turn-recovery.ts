import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"
import { settleGoalOnTurnEnd } from "./goals.js"
import { isRecord } from "./internal.js"
import { cancelClaudePendingQuestions } from "./questions.js"
import type { ClaudeSession } from "./session.js"
import {
  ensureObservedTurnStarted,
  finishActiveTurn,
  refreshClaudeSessionTitle
} from "./turn-lifecycle.js"
import {
  claudeContextWindowFrom,
  rejectedUsageLimitDetail,
  usageLimitTextFromResult
} from "./usage.js"

/// Model-level stop reasons that mean "I ran out of room, not out of work":
/// the assistant message was truncated by the per-response output-token cap.
/// The SDK reports this as an ordinary `success` result, so on its own the
/// provider would end the turn — the "Claude just stopped mid-task" symptom,
/// where the user had to nudge it with "continue" by hand. The provider resumes
/// automatically instead; see `handleResult`.
const TRUNCATION_STOP_REASONS = new Set(["max_tokens"])

/// SDK assistant-message `error` values that will fail identically on retry —
/// the request/credentials/model are wrong. These end the turn and surface a
/// reason. Everything else on `error_during_execution` (overloaded, rate_limit,
/// server_error, `unknown`, or no error at all) is treated as transient and
/// retried with backoff — a bounded retry is the safe default so we never
/// silently swallow a recoverable failure.
const PERMANENT_ASSISTANT_ERRORS = new Set([
  "authentication_failed",
  "oauth_org_not_allowed",
  "billing_error",
  "invalid_request",
  "model_not_found"
])

/// SDK assistant-message `error` values that are transient (the API was busy,
/// not the request being wrong) — worth an automatic retry. `unknown` is
/// included so an unclassified `error_during_execution` still retries rather
/// than surfacing immediately.
const TRANSIENT_ASSISTANT_ERRORS = new Set(["overloaded", "rate_limit", "server_error", "unknown"])

/// Silent truncation continuations allowed per turn: an output-token-truncated
/// response legitimately has more to say, so this is generous. Past it the turn
/// ends and surfaces the truncation.
const MAX_TRUNCATION_CONTINUATIONS = 12

/// Visible transient retries allowed per turn (529 overload, rate-limit, server
/// error), on top of the SDK's own internal retries. Past it the turn ends and
/// the error is surfaced to the user.
const MAX_TRANSIENT_RETRIES = 3

/// Escalating backoff before a *transient* retry (~1s, 2s, 4s), so we don't
/// hammer an overloaded API. Truncation continuations use no delay.
const RECOVERY_BACKOFF_BASE_MS = 1000
const RECOVERY_BACKOFF_CAP_MS = 8000
const recoveryBackoffMs = (retryIndex: number): number =>
  Math.min(RECOVERY_BACKOFF_BASE_MS * 2 ** retryIndex, RECOVERY_BACKOFF_CAP_MS)

/// The nudge pushed to resume a recoverable turn — the same thing a user would
/// type. Pushed straight into the SDK input queue, so it never surfaces as a
/// visible user message (the `user` echo carries no tool_result to forward).
const CONTINUE_PROMPT = "Please continue."

type TurnResolution =
  | { readonly kind: "continue" }
  | { readonly kind: "retry"; readonly delayMs: number; readonly attempt: number }
  | {
      readonly kind: "end"
      readonly stopReason: string
      readonly stopDetail?: string | undefined
      readonly stopKind?: "usageLimit" | undefined
      readonly retryable?: boolean | undefined
    }

/// Classifies an SDK `result`:
///  - output-token truncation (`max_tokens`/`max_output_tokens`) or the
///    turn-count limit → silent `continue` (bounded by MAX_TRUNCATION_CONTINUATIONS);
///  - a transient API failure (`error_during_execution`, a transient assistant
///    `error`, or a detected "API Error: 5xx" text) → visible `retry` with
///    backoff (bounded by MAX_TRANSIENT_RETRIES);
///  - otherwise `end`, surfacing a reason for a refusal, permanent error, hit
///    limit, or exhausted retries.
const classifyResult = (
  session: ClaudeSession,
  message: SDKMessage & { type: "result" }
): TurnResolution => {
  if (session.interruptRequested) return { kind: "end", stopReason: "cancelled" }

  const subtype = message.subtype
  const stopReasonRaw = typeof message.stop_reason === "string" ? message.stop_reason : ""
  const lastError = session.lastAssistantError ?? ""
  const resultUsageLimitText = usageLimitTextFromResult(message)
  const usageLimitDetail =
    resultUsageLimitText ??
    session.lastUsageLimitText ??
    (lastError === "rate_limit" || lastError === "billing_error"
      ? rejectedUsageLimitDetail(session.latestRateLimitInfo)
      : undefined)
  const usageLimitExceeded =
    usageLimitDetail !== undefined &&
    (message.is_error === true ||
      subtype !== "success" ||
      lastError === "rate_limit" ||
      lastError === "billing_error")

  // Claude distinguishes genuine subscription/credit exhaustion from a
  // temporary request-rate 429 through its canonical user-facing messages and
  // rejected rate_limit_event state. Retrying cannot help in this case.
  if (usageLimitExceeded) {
    return {
      kind: "end",
      stopReason: "end_turn",
      stopDetail: usageLimitDetail,
      stopKind: "usageLimit"
    }
  }

  const truncated =
    (subtype === "success" && TRUNCATION_STOP_REASONS.has(stopReasonRaw)) ||
    lastError === "max_output_tokens"
  const turnLimit = subtype === "error_max_turns"
  const permanentError = subtype !== "success" && PERMANENT_ASSISTANT_ERRORS.has(lastError)
  // Transient covers an error_during_execution result, a transient assistant
  // error, or a 529-style error that arrived as text — regardless of the result
  // subtype (a 529 can surface as a `success` with the error baked into text).
  const transient =
    !permanentError &&
    (subtype === "error_during_execution" || TRANSIENT_ASSISTANT_ERRORS.has(lastError))

  // Silent continuation: the response was truncated (or hit the turn limit) and
  // legitimately has more to say. No delay, no visible status.
  if ((truncated || turnLimit) && session.truncationCount < MAX_TRUNCATION_CONTINUATIONS) {
    return { kind: "continue" }
  }
  // Visible retry: a transient API failure, backed off and shown to the user.
  if (transient && session.transientRetries < MAX_TRANSIENT_RETRIES) {
    return {
      kind: "retry",
      delayMs: recoveryBackoffMs(session.transientRetries),
      attempt: session.transientRetries + 1
    }
  }

  // Terminal. A genuinely clean success ends quietly, noting only a refusal or a
  // truncation we gave up on.
  if (subtype === "success" && !transient) {
    const stopDetail =
      stopReasonRaw === "refusal"
        ? "Claude declined to respond."
        : truncated
          ? "Response hit the output-token limit."
          : undefined
    return { kind: "end", stopReason: "end_turn", stopDetail }
  }
  // An error, or a transient failure whose retries are spent: surface the real
  // API error text when we have it, else a described reason.
  return {
    kind: "end",
    stopReason: subtype === "error_max_turns" ? "max_turn_requests" : "end_turn",
    ...(transient ? { retryable: true } : {}),
    stopDetail:
      transient && session.lastErrorText !== undefined
        ? session.lastErrorText
        : describeStop(subtype, lastError)
  }
}

/// A short, human-readable reason for a turn that ended abnormally, rendered
/// under the turn in the transcript (there is no clean-completion string).
const describeStop = (subtype: string, lastError: string): string => {
  switch (lastError) {
    case "overloaded":
      return "The Claude API was overloaded."
    case "rate_limit":
      return "Rate limited by the Claude API."
    case "server_error":
      return "The Claude API returned a server error."
    case "authentication_failed":
      return "Claude authentication failed."
    case "oauth_org_not_allowed":
      return "This organization isn't allowed to use this model."
    case "billing_error":
      return "A billing error stopped the turn."
    case "invalid_request":
      return "The request was rejected as invalid."
    case "model_not_found":
      return "The selected model is unavailable."
    default:
      break
  }
  switch (subtype) {
    case "error_max_turns":
      return "Reached the maximum number of turns."
    case "error_max_budget_usd":
      return "Reached the usage budget."
    case "error_max_structured_output_retries":
      return "Couldn't produce valid structured output."
    default:
      return "Claude Code ended the turn unexpectedly."
  }
}

const pushContinuePrompt = (session: ClaudeSession): void => {
  session.input.push({
    message: { content: CONTINUE_PROMPT, role: "user" },
    parent_tool_use_id: null,
    session_id: session.sdkSessionId,
    type: "user"
  })
}

/// Resumes the live turn after a recoverable stop by pushing a continue nudge.
/// A positive delay (transient backoff) is scheduled; the callback bails if the
/// session was closed while waiting, so a timer can never resume a dead session.
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

/// Emits a visible retry reason while Codevisor's outer recovery is active.
/// The client clears it when the next output arrives or the turn ends.
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

/// Dev-only turn-end trace (gated on CODEVISOR_DEBUG). The provider has no logger;
/// this matches the plain-console style used in apps/server/src/main.ts. This is
/// how we learn the real dominant stop reason without shipping any UI noise.
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

  // Claude emits independent results for model follow-ups caused by background
  // task notifications. If one interleaves with the user's live turn, it must
  // not finish that turn, clear its questions, or settle its goal. When the
  // follow-up produced visible top-level output after the user turn, our stream
  // handlers opened an agent-initiated display turn; allow only that turn to
  // close below.
  if (isTaskNotification && (!session.turnActive || session.initiatedBy === "user")) return
  // A slash-command response can contain no assistant content. Still open its
  // observed turn so the queued user initiator is consumed and the terminal
  // event cannot be mistaken for unrelated autonomous activity.
  if (!session.turnActive) void ensureObservedTurnStarted(session)

  const assistantError = session.lastAssistantError
  const resolution = classifyResult(session, message)
  const authFailure =
    assistantError === "authentication_failed" || assistantError === "oauth_org_not_allowed"
  if (process.env.CODEVISOR_DEBUG !== undefined || process.env.HERDMAN_DEBUG !== undefined) {
    logTurnEnd(session, message, resolution)
  }
  // Each `result` is classified on the assistant error seen since the previous
  // one; consume it so a stale error can't misclassify a later leg.
  session.lastAssistantError = undefined
  session.lastUsageLimitText = undefined
  session.latestRateLimitInfo = undefined

  if (resolution.kind === "continue") {
    // Output truncated — resume the same turn immediately and invisibly; the
    // model just had more to say.
    session.truncationCount += 1
    scheduleRecovery(session, 0)
    return
  }
  if (resolution.kind === "retry") {
    // Transient API failure — show "Retrying…", back off, then resume. The turn
    // stays alive; turnId/pendingPrompt are untouched.
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

  // Terminal. A turn that ends with questions still open (interrupt, failure)
  // invalidates them — clients must not keep showing the picker.
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
  cancelClaudePendingQuestions(session)
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

import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"

import type { ClaudeSession } from "./session.js"
import { rejectedUsageLimitDetail, usageLimitTextFromResult } from "./usage.js"

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
export const MAX_TRANSIENT_RETRIES = 3

/// Escalating backoff before a *transient* retry (~1s, 2s, 4s), so we don't
/// hammer an overloaded API. Truncation continuations use no delay.
const RECOVERY_BACKOFF_BASE_MS = 1000
const RECOVERY_BACKOFF_CAP_MS = 8000
const recoveryBackoffMs = (retryIndex: number): number =>
  Math.min(RECOVERY_BACKOFF_BASE_MS * 2 ** retryIndex, RECOVERY_BACKOFF_CAP_MS)

export type TurnResolution =
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
export const classifyResult = (
  session: ClaudeSession,
  message: SDKMessage & { type: "result" }
): TurnResolution => {
  if (session.interruptRequested) return { kind: "end", stopReason: "cancelled" }

  const subtype = message.subtype
  const stopReasonRaw = typeof message.stop_reason === "string" ? message.stop_reason : ""
  const lastError = session.lastAssistantError ?? ""
  const usageLimit = usageLimitResolution(session, message, subtype, lastError)
  if (usageLimit !== undefined) return usageLimit
  return recoveryResolution(session, subtype, stopReasonRaw, lastError)
}

const resolveUsageLimitDetail = (
  session: ClaudeSession,
  message: SDKMessage & { type: "result" },
  lastError: string
): string | undefined => {
  const resultUsageLimitText = usageLimitTextFromResult(message)
  return (
    resultUsageLimitText ??
    session.lastUsageLimitText ??
    (lastError === "rate_limit" || lastError === "billing_error"
      ? rejectedUsageLimitDetail(session.latestRateLimitInfo)
      : undefined)
  )
}

const usageLimitResolution = (
  session: ClaudeSession,
  message: SDKMessage & { type: "result" },
  subtype: string,
  lastError: string
): TurnResolution | undefined => {
  const usageLimitDetail = resolveUsageLimitDetail(session, message, lastError)
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

  return undefined
}

const recoveryResolution = (
  session: ClaudeSession,
  subtype: string,
  stopReasonRaw: string,
  lastError: string
): TurnResolution => {
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

  const recovery = boundedRecovery(session, truncated, turnLimit, transient)
  if (recovery !== undefined) return recovery
  return terminalResolution(session, subtype, stopReasonRaw, lastError, truncated, transient)
}

const boundedRecovery = (
  session: ClaudeSession,
  truncated: boolean,
  turnLimit: boolean,
  transient: boolean
): TurnResolution | undefined => {
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

  return undefined
}

const terminalResolution = (
  session: ClaudeSession,
  subtype: string,
  stopReasonRaw: string,
  lastError: string,
  truncated: boolean,
  transient: boolean
): TurnResolution => {
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

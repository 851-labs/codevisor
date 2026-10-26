import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"
import { harnessFailureStop, usageLimitStop } from "@codevisor/agent-runtime"
import type { TurnStopKind } from "@codevisor/api"

import { recordOf } from "./internal.js"
import type { ClaudeSession } from "./session.js"
import {
  rejectedUsageLimitDetail,
  rejectedUsageLimitReset,
  usageLimitTextFromResult
} from "./usage.js"

const TRUNCATION_STOP_REASONS = new Set(["max_tokens"])

const PERMANENT_ASSISTANT_ERRORS = new Set([
  "authentication_failed",
  "oauth_org_not_allowed",
  "billing_error",
  "invalid_request",
  "model_not_found"
])

const LIMIT_SUBTYPES = new Set([
  "error_max_turns",
  "error_max_budget_usd",
  "error_max_structured_output_retries"
])

const TRANSIENT_ASSISTANT_ERRORS = new Set(["overloaded", "rate_limit", "server_error", "unknown"])

const MAX_TRUNCATION_CONTINUATIONS = 12

export const MAX_TRANSIENT_RETRIES = 3

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
      readonly stopKind?: TurnStopKind | undefined
      readonly retryable?: boolean | undefined
      readonly resetsAt?: string | undefined
    }

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
  if (PERMANENT_ASSISTANT_ERRORS.has(lastError)) {
    return permanentErrorResolution(session, message, subtype, lastError)
  }
  return recoveryResolution(session, subtype, stopReasonRaw, lastError)
}

const permanentErrorResolution = (
  session: ClaudeSession,
  message: SDKMessage & { type: "result" },
  subtype: string,
  lastError: string
): TurnResolution => {
  const failure = {
    message: permanentErrorDetail(session, subtype, lastError),
    status: apiErrorStatus(message),
    code: lastError
  }
  return { kind: "end", stopReason: "end_turn", ...harnessFailureStop(failure) }
}

const apiErrorStatus = (message: SDKMessage & { type: "result" }): number | undefined => {
  const status = recordOf(message).api_error_status
  return typeof status === "number" ? status : undefined
}

const permanentErrorDetail = (
  session: ClaudeSession,
  subtype: string,
  lastError: string
): string => {
  if (lastError === "authentication_failed") return describeStop(subtype, lastError)
  return session.lastErrorText ?? describeStop(subtype, lastError)
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
    (message.is_error ||
      subtype !== "success" ||
      lastError === "rate_limit" ||
      lastError === "billing_error")

  if (usageLimitExceeded) {
    return {
      kind: "end",
      stopReason: "end_turn",
      ...usageLimitStop(usageLimitDetail, rejectedUsageLimitReset(session.latestRateLimitInfo))
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
  const transient =
    subtype === "error_during_execution" || TRANSIENT_ASSISTANT_ERRORS.has(lastError)

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
  if ((truncated || turnLimit) && session.truncationCount < MAX_TRUNCATION_CONTINUATIONS) {
    return { kind: "continue" }
  }
  if (transient && session.transientRetries < MAX_TRANSIENT_RETRIES) {
    return {
      kind: "retry",
      delayMs: recoveryBackoffMs(session.transientRetries),
      attempt: session.transientRetries + 1
    }
  }

  return undefined
}

const successStopDetail = (stopReasonRaw: string, truncated: boolean) => {
  if (stopReasonRaw === "refusal") return "Claude declined to respond."
  if (truncated) return "Response hit the output-token limit."
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
  if (subtype === "success" && !transient) {
    const stopDetail = successStopDetail(stopReasonRaw, truncated)
    return { kind: "end", stopReason: "end_turn", stopDetail }
  }
  return {
    kind: "end",
    stopReason: subtype === "error_max_turns" ? "max_turn_requests" : "end_turn",
    ...(transient ? { retryable: true } : {}),
    ...(LIMIT_SUBTYPES.has(subtype) ? {} : { stopKind: "harnessFailed" }),
    stopDetail:
      transient && session.lastErrorText !== undefined
        ? session.lastErrorText
        : describeStop(subtype, lastError)
  }
}

const describeStop = (subtype: string, lastError: string): string => {
  switch (lastError) {
    case "overloaded":
      return "The Claude API was overloaded."
    case "rate_limit":
      return "Rate limited by the Claude API."
    case "server_error":
      return "The Claude API returned a server error."
    case "authentication_failed":
      return "Claude isn't signed in. Sign in to continue."
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

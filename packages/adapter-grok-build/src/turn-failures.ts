import type { AcpPromptResult } from "@codevisor/adapter-acp"
import { usageLimitStop } from "@codevisor/agent-runtime"

import { unwrapGrokExtensionParams } from "./grok.js"
import { record, type JsonRecord } from "./record.js"

export interface GrokTurnFailure {
  readonly sessionId: string
  readonly stop: AcpPromptResult
}

export const grokSignedOutStop: AcpPromptResult = {
  stopDetail: "Grok Build isn't signed in. Sign in to continue.",
  stopKind: "authRequired",
  stopReason: "end_turn"
}

export const grokTurnFailure = (params: unknown): GrokTurnFailure | undefined => {
  const notification = record(unwrapGrokExtensionParams(params))
  const update = record(notification?.update)
  if (typeof notification?.sessionId !== "string" || update?.sessionUpdate !== "retry_state") {
    return undefined
  }

  const stop = retryStateStop(update)
  return stop === undefined ? undefined : { sessionId: notification.sessionId, stop }
}

const freeUsageExhaustedCode = "subscription:free-usage-exhausted"

const paymentRequiredStatus = /\bstatus 402\b/

const forbiddenStatus = /\bstatus 403\b/

const outOfCreditsText = /run out of credits/i

const apiErrorPrefix = /^API error \([^)]*\):\s*/

const subscriptionCodePrefix = /^subscription:[\w-]+:\s*/

const retryStateStop = (update: JsonRecord): AcpPromptResult | undefined => {
  if (isAuthFailure(update)) return grokSignedOutStop

  const detail = usageLimitDetail(update)
  if (detail === undefined) return undefined

  return { stopReason: "end_turn", ...usageLimitStop(detail) }
}

const isAuthFailure = (update: JsonRecord): boolean =>
  update.type === "failed" && update.error_type === "auth"

const usageLimitDetail = (update: JsonRecord): string | undefined => {
  if (isFreeUsageExhausted(update)) return withoutErrorCodes(String(update.reason))
  if (isOutOfCredits(update)) return withoutErrorCodes(String(update.message))
  return undefined
}

const isFreeUsageExhausted = (update: JsonRecord): boolean =>
  update.type === "exhausted" &&
  update.is_rate_limited === true &&
  typeof update.reason === "string" &&
  update.reason.includes(freeUsageExhaustedCode)

const isOutOfCredits = (update: JsonRecord): boolean =>
  update.type === "failed" &&
  update.error_type === "api" &&
  typeof update.message === "string" &&
  isCreditsMessage(update.message)

const isCreditsMessage = (message: string): boolean =>
  paymentRequiredStatus.test(message) ||
  (forbiddenStatus.test(message) && outOfCreditsText.test(message))

const withoutErrorCodes = (text: string): string =>
  text.replace(apiErrorPrefix, "").replace(subscriptionCodePrefix, "").trim()

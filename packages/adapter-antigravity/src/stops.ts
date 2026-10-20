import { resetTimeIn, usageLimitStop } from "@codevisor/agent-runtime"

import { signedOut, SIGN_IN_DETAIL } from "./protocol.js"

export interface AgyStop {
  readonly stopDetail: string
  readonly stopKind?: "authRequired" | "usageLimit"
  readonly resetsAt?: string
}

export const failureDetail = (message: string | undefined): string => {
  if (message === undefined) return genericFailureDetail
  if (signedOut(message)) return SIGN_IN_DETAIL
  return message
}

export const agyStop = (stopDetail: string): AgyStop => {
  if (stopDetail === SIGN_IN_DETAIL) return { stopDetail, stopKind: "authRequired" }
  if (usageLimited(stopDetail)) return usageLimitStop(stopDetail, resetTimeIn(stopDetail))
  return { stopDetail }
}

const genericFailureDetail = "Antigravity stopped with an error."

const quotaExhausted = /RESOURCE_EXHAUSTED \(code 429\)/

const individualQuotaReached = /individual quota reached/i

const creditsTooLow = /Your AI credits balance is too low to continue\./

const individualQuotaExhausted = (stopDetail: string): boolean =>
  quotaExhausted.test(stopDetail) && individualQuotaReached.test(stopDetail)

const usageLimited = (stopDetail: string): boolean =>
  individualQuotaExhausted(stopDetail) || creditsTooLow.test(stopDetail)

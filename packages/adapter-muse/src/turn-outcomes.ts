import { epochResetTime, usageLimitStop } from "@codevisor/agent-runtime"
import { isPlainRecord } from "@codevisor/api"

import { record, text } from "./protocol.js"

export interface TurnOutcome {
  readonly stopDetail?: string
  readonly stopKind?: "authRequired" | "usageLimit"
  readonly resetsAt?: string
  readonly retryable?: boolean
  readonly cancelled?: boolean
}

export const signedOutOutcome: TurnOutcome = {
  stopDetail: "Sign in to Muse Code to continue.",
  stopKind: "authRequired"
}

export const completedOutcome = (event: Record<string, unknown>): TurnOutcome => {
  if (event.terminal === "cancelled") return { cancelled: true }
  if (event.terminal !== "failed") return {}
  return failedOutcome(record(event.error), text(event.reason))
}

const genericFailureDetail = "Muse stopped with an error."

const failedOutcome = (error: Record<string, unknown>, reason: string | undefined): TurnOutcome => {
  if (error.kind === "authRequired") return signedOutOutcome

  const stopDetail = text(error.message) ?? reason ?? genericFailureDetail
  if (isPlainRecord(error.quota)) return quotaOutcome(stopDetail, error.quota)
  if (error.retryable === true) return { stopDetail, retryable: true }
  return { stopDetail }
}

const quotaOutcome = (stopDetail: string, quota: Record<string, unknown>): TurnOutcome =>
  usageLimitStop(stopDetail, epochResetTime(quota.resetsAtMs, "milliseconds"))

import { resetTimeIn, usageLimitStop } from "@codevisor/agent-runtime"

import type { PiAssistantOutcome } from "./events.js"

export interface PiStop {
  readonly stopDetail: string
  readonly stopKind?: "usageLimit"
  readonly resetsAt?: string
}

export const failureDetail = (
  cancelled: boolean,
  outcome: PiAssistantOutcome | undefined
): string | undefined => {
  if (cancelled || outcome?.stopReason !== "error") return undefined
  return outcome.errorMessage ?? genericFailureDetail
}

export const piStop = (stopDetail: string): PiStop => {
  if (!isUsageLimit(stopDetail)) return { stopDetail }
  return usageLimitStop(stopDetail, resetTimeIn(stopDetail))
}

const genericFailureDetail = "Pi stopped with an error."

const chatGptUsageLimit =
  /^You have hit your ChatGPT usage limit(?: \(\w+ plan\))?\.(?: Try again in ~\d+ min\.)?$/

const codexUsageLimit = /^Codex error: .*\busage limit\b/i

const openCodeUsageLimit =
  /\b(?:GoUsageLimitError|FreeUsageLimitError)\b|Monthly usage limit reached/

const usageLimitPatterns = [chatGptUsageLimit, codexUsageLimit, openCodeUsageLimit]

const isUsageLimit = (stopDetail: string): boolean =>
  usageLimitPatterns.some((pattern) => pattern.test(stopDetail))

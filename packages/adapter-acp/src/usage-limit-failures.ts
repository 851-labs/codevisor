import * as acp from "@agentclientprotocol/sdk"
import { isOutOfCreditsText, resetTimeIn, usageLimitStop } from "@codevisor/agent-runtime"
import { isRecord } from "@codevisor/api"

import type { AcpPromptResult } from "./connection.js"

export interface AcpRequestFailure {
  readonly code: number
  readonly message: string
  readonly data?: unknown
}

export type AcpUsageLimitRule = (failure: AcpRequestFailure) => boolean

export const usageLimitPromptStop = (
  cause: unknown,
  harnessRule: AcpUsageLimitRule = () => false
): AcpPromptResult | undefined => {
  if (!(cause instanceof acp.RequestError)) return undefined
  if (!isAcpUsageLimit(cause) && !harnessRule(cause)) return undefined

  const detail = userFacingDetail(cause.message)
  return { stopReason: "end_turn", ...usageLimitStop(detail, resetTimeIn(detail)) }
}

const tooManyRequestsCode = 429
const internalErrorCode = -32603

const geminiQuotaText =
  /exhausted your (?:daily quota|capacity)|quota will reset after|INSUFFICIENT_G1_CREDITS|limit:\s*0(?![\d.])|Suggested retry after \d/i

const claudeUsageLimitText = /You[’']ve hit your/i

const internalErrorPrefix = /^Internal error:\s*/

const geminiTip = /\n\n💡 Tip:[\s\S]*$/

const isAcpUsageLimit = (failure: AcpRequestFailure): boolean =>
  isGeminiQuotaExhausted(failure) ||
  isCodexUsageLimit(failure) ||
  isClaudeUsageLimit(failure) ||
  isClaudeBillingError(failure) ||
  isOutOfCreditsText(failure.message)

const isGeminiQuotaExhausted = (failure: AcpRequestFailure): boolean =>
  failure.code === tooManyRequestsCode && geminiQuotaText.test(failure.message)

const isCodexUsageLimit = (failure: AcpRequestFailure): boolean =>
  failure.code === internalErrorCode &&
  dataField(failure, "codexErrorInfo") === "usageLimitExceeded"

const isClaudeUsageLimit = (failure: AcpRequestFailure): boolean =>
  failure.code === internalErrorCode &&
  dataField(failure, "errorKind") === "rate_limit" &&
  claudeUsageLimitText.test(failure.message)

const isClaudeBillingError = (failure: AcpRequestFailure): boolean =>
  failure.code === internalErrorCode && dataField(failure, "errorKind") === "billing_error"

export const dataField = (failure: AcpRequestFailure, key: string): unknown =>
  isRecord(failure.data) ? failure.data[key] : undefined

export const userFacingDetail = (message: string): string =>
  message.replace(internalErrorPrefix, "").replace(geminiTip, "").trim()

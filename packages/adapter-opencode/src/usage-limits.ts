import type { AcpRequestFailure } from "@codevisor/adapter-acp"

export const isOpenCodeUsageLimitMessage = (message: string): boolean =>
  usageLimitText.test(message)

export const isOpenCodeUsageLimit = (failure: AcpRequestFailure): boolean =>
  failure.code === internalErrorCode && isOpenCodeUsageLimitMessage(failure.message)

const internalErrorCode = -32603

const usageLimitText =
  /The usage limit has been reached|Quota exceeded\. Check your plan and billing details|To use Codex with your ChatGPT plan, upgrade/i

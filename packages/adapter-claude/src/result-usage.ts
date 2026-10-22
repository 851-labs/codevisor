import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"

import { isRecord, recordOf } from "./internal.js"
import { claudeContextWindowFrom } from "./session-context.js"
import type { ClaudeSession } from "./session.js"

interface ResultUsage {
  readonly tokens: TokenUsage
  readonly costAmount: number | undefined
  readonly context: ContextUsage
}

interface TokenUsage {
  readonly inputTokens: number | undefined
  readonly cachedInputTokens: number
  readonly outputTokens: number | undefined
  readonly totalTokens: number | undefined
}

interface ContextUsage {
  readonly used: number | undefined
  readonly size: number | undefined
}

export const emitResultUsage = (
  session: ClaudeSession,
  message: SDKMessage & { type: "result" }
): void => {
  const usage = resultUsage(session, message)
  if (!reportsUsage(usage)) return

  void session.emit({
    kind: "session.updated",
    payload: usageUpdate(usage),
    subjectId: session.key
  })
}

const resultUsage = (
  session: ClaudeSession,
  message: SDKMessage & { type: "result" }
): ResultUsage => {
  const raw = recordOf(message)
  return {
    tokens: tokenUsage(raw),
    costAmount: finiteNumberAt(raw, "total_cost_usd"),
    context: contextUsage(session, raw)
  }
}

const tokenUsage = (raw: Record<string, unknown>): TokenUsage => {
  const usage = isRecord(raw.usage) ? raw.usage : {}
  const inputTokens = finiteNumberAt(usage, "input_tokens")
  const cachedInputTokens =
    (finiteNumberAt(usage, "cache_creation_input_tokens") ?? 0) +
    (finiteNumberAt(usage, "cache_read_input_tokens") ?? 0)
  const outputTokens = finiteNumberAt(usage, "output_tokens")
  return {
    inputTokens,
    cachedInputTokens,
    outputTokens,
    totalTokens: totalTokens(inputTokens, cachedInputTokens, outputTokens)
  }
}

const totalTokens = (
  inputTokens: number | undefined,
  cachedInputTokens: number,
  outputTokens: number | undefined
): number | undefined => {
  if (noTokensReported(inputTokens, cachedInputTokens, outputTokens)) return undefined
  return (inputTokens ?? 0) + cachedInputTokens + (outputTokens ?? 0)
}

const noTokensReported = (
  inputTokens: number | undefined,
  cachedInputTokens: number,
  outputTokens: number | undefined
): boolean => inputTokens === undefined && outputTokens === undefined && cachedInputTokens === 0

const finiteNumberAt = (record: Record<string, unknown>, key: string): number | undefined =>
  typeof record[key] === "number" && Number.isFinite(record[key]) ? record[key] : undefined

const contextUsage = (session: ClaudeSession, raw: Record<string, unknown>): ContextUsage => ({
  used: session.latestContextUsage?.used,
  size: claudeContextWindowFrom(
    raw.modelUsage,
    session.latestContextUsage?.model,
    session.currentModel
  )
})

const reportsUsage = (usage: ResultUsage): boolean =>
  usage.tokens.totalTokens !== undefined ||
  usage.costAmount !== undefined ||
  usage.context.used !== undefined

const usageUpdate = ({ tokens, costAmount, context }: ResultUsage) => ({
  sessionUpdate: "usage_update",
  ...(context.used === undefined ? {} : { used: context.used }),
  ...(context.size === undefined ? {} : { size: context.size }),
  ...(tokens.inputTokens === undefined ? {} : { inputTokens: tokens.inputTokens }),
  ...(tokens.cachedInputTokens === 0 ? {} : { cachedInputTokens: tokens.cachedInputTokens }),
  ...(tokens.outputTokens === undefined ? {} : { outputTokens: tokens.outputTokens }),
  ...(tokens.totalTokens === undefined ? {} : { totalTokens: tokens.totalTokens }),
  ...(costAmount === undefined ? {} : { cost: reportedCost(costAmount) })
})

const reportedCost = (amount: number) => ({ amount, currency: "USD", kind: "reported" })

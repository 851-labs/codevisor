import type * as acp from "@agentclientprotocol/sdk"
import type { TurnTokens } from "@codevisor/agent-runtime"

export const turnTokensOf = (usage: acp.Usage | null | undefined): TurnTokens | undefined => {
  if (usage === null || usage === undefined) return undefined

  return {
    inputTokens: usage.inputTokens,
    outputTokens: usage.outputTokens,
    totalTokens: usage.totalTokens,
    ...optional("cachedInputTokens", usage.cachedReadTokens),
    ...optional("reasoningOutputTokens", usage.thoughtTokens)
  }
}

const optional = (field: keyof TurnTokens, value: number | null | undefined) =>
  value === null || value === undefined ? {} : { [field]: value }

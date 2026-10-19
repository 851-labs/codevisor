import type { SDKControlGetContextUsageResponse } from "@anthropic-ai/claude-agent-sdk"
import type { SessionContext } from "@codevisor/api"

import { isRecord } from "./internal.js"

export const claudeContextUsageFromAssistant = (
  value: unknown
): { model: string | undefined; used: number } | undefined => {
  if (!isRecord(value)) return undefined
  const usage = value.usage
  if (!isRecord(usage)) return undefined
  const token = (key: string): number | undefined => {
    const candidate = usage[key]
    return typeof candidate === "number" && Number.isFinite(candidate) && candidate >= 0
      ? candidate
      : undefined
  }
  const input = token("input_tokens")
  const cacheCreation = token("cache_creation_input_tokens")
  const cacheRead = token("cache_read_input_tokens")
  if (input === undefined && cacheCreation === undefined && cacheRead === undefined)
    return undefined
  return {
    model: typeof value.model === "string" ? value.model : undefined,
    used: (input ?? 0) + (cacheCreation ?? 0) + (cacheRead ?? 0)
  }
}

const contextWindowOf = (entry: unknown): number | undefined => {
  if (!isRecord(entry)) return undefined
  const candidate = entry.contextWindow
  return typeof candidate === "number" && Number.isFinite(candidate) && candidate > 0
    ? candidate
    : undefined
}

export const claudeContextWindowFrom = (
  value: unknown,
  latestModel: string | undefined,
  configuredModel: string
): number | undefined => {
  if (!isRecord(value)) return undefined
  for (const model of [latestModel, configuredModel]) {
    if (model === undefined || model === "") continue
    const matched = contextWindowOf(value[model])
    if (matched !== undefined) return matched
  }
  const available = new Set(
    Object.values(value)
      .map(contextWindowOf)
      .filter((size) => size !== undefined)
  )
  return available.size === 1 ? available.values().next().value : undefined
}

export const claudeSessionContextFrom = (
  response: SDKControlGetContextUsageResponse
): SessionContext => ({
  ...(response.model === "" ? {} : { model: response.model }),
  totalTokens: response.totalTokens,
  maxTokens: response.maxTokens,
  categories: response.categories.map((category) => ({
    name: category.name,
    tokens: category.tokens,
    color: category.color,
    ...(category.isDeferred === undefined ? {} : { isDeferred: category.isDeferred })
  })),
  mcpTools: response.mcpTools.map((tool) => ({
    name: tool.name,
    serverName: tool.serverName,
    tokens: tool.tokens,
    ...(tool.isLoaded === undefined ? {} : { isLoaded: tool.isLoaded })
  }))
})

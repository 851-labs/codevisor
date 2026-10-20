import type { HarnessUsageLimits, SessionContext } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"

import { isRecord } from "./internal.js"

const usageWindowLabel = (durationMinutes: number | undefined, fallback: string): string => {
  if (durationMinutes === 300) return "5-hour limit"
  if (durationMinutes === 10_080) return "Weekly limit"
  if (durationMinutes !== undefined && durationMinutes % 1_440 === 0) {
    return `${durationMinutes / 1_440}-day limit`
  }
  if (durationMinutes !== undefined && durationMinutes % 60 === 0) {
    return `${durationMinutes / 60}-hour limit`
  }
  return fallback
}

const codexUsageWindow = (
  value: unknown,
  id: string,
  fallbackLabel: string
): HarnessUsageLimits["windows"][number] | undefined => {
  if (!isRecord(value) || typeof value.usedPercent !== "number") return undefined
  const durationMinutes =
    typeof value.windowDurationMins === "number" ? value.windowDurationMins : undefined
  const resetSeconds = typeof value.resetsAt === "number" ? value.resetsAt : undefined
  return {
    id,
    label: usageWindowLabel(durationMinutes, fallbackLabel),
    usedPercent: Math.max(0, Math.min(100, value.usedPercent)),
    ...(durationMinutes === undefined ? {} : { durationMinutes }),
    ...(resetSeconds === undefined ? {} : { resetsAt: new Date(resetSeconds * 1000).toISOString() })
  }
}

export const codexUsageLimitsFrom = (response: unknown): HarnessUsageLimits => {
  const root = isRecord(response) ? response : {}
  const limits = isRecord(root.rateLimits) ? root.rateLimits : root
  const primary = codexUsageWindow(limits.primary, "primary", "Primary limit")
  const secondary = codexUsageWindow(limits.secondary, "secondary", "Secondary limit")
  const credits = isRecord(limits.credits) ? limits.credits : undefined
  const windows = [primary, secondary].filter(
    (window): window is NonNullable<typeof window> => window !== undefined
  )
  return {
    fetchedAt: isoTimestamp(),
    harnessId: "codex",
    ...(typeof limits.planType === "string" ? { plan: limits.planType } : {}),
    state: windows.length > 0 ? "available" : "unavailable",
    windows,
    ...(credits === undefined
      ? {}
      : {
          credits: {
            hasCredits: credits.hasCredits === true,
            unlimited: credits.unlimited === true,
            ...(typeof credits.balance === "string"
              ? { balance: credits.balance }
              : typeof credits.balance === "number"
                ? { balance: String(credits.balance) }
                : {})
          }
        }),
    ...(windows.length > 0
      ? {}
      : { detail: "Codex did not return subscription usage limits for this account." })
  }
}

export const exhaustedWindowReset = (
  limits: HarnessUsageLimits | undefined
): string | undefined => {
  const resets = (limits?.windows ?? []).filter(isExhausted).flatMap(windowReset)
  if (resets.length === 0) return undefined

  return new Date(Math.max(...resets)).toISOString()
}

const exhaustedPercent = 100

type UsageWindow = HarnessUsageLimits["windows"][number]

const isExhausted = (window: UsageWindow): boolean => window.usedPercent >= exhaustedPercent

const windowReset = (window: UsageWindow): ReadonlyArray<number> =>
  window.resetsAt === undefined ? [] : [Date.parse(window.resetsAt)]

const tokenCount = (record: Record<string, unknown>, key: string): number => {
  const value = record[key]
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : 0
}

export const codexSessionContextFrom = (tokenUsage: unknown): SessionContext | undefined => {
  if (!isRecord(tokenUsage) || !isRecord(tokenUsage.last)) return undefined
  const maxTokens = tokenCount(tokenUsage, "modelContextWindow")
  if (maxTokens === 0) return undefined
  const last = tokenUsage.last
  const input = tokenCount(last, "inputTokens")
  const cached = Math.min(tokenCount(last, "cachedInputTokens"), input)
  const output = tokenCount(last, "outputTokens")
  const reasoning = Math.min(tokenCount(last, "reasoningOutputTokens"), output)
  const totalTokens = tokenCount(last, "totalTokens") || input + output
  const categories = [
    { name: "Input", tokens: input - cached },
    { name: "Cached input", tokens: cached },
    { name: "Output", tokens: output - reasoning },
    { name: "Reasoning", tokens: reasoning },
    { name: "Free space", tokens: Math.max(maxTokens - totalTokens, 0) }
  ].filter((category) => category.tokens > 0)
  return { totalTokens, maxTokens, categories, mcpTools: [] }
}

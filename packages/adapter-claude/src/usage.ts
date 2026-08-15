import {
  USAGE_LIMIT_ERROR_PREFIXES,
  type SDKControlGetUsageResponse,
  type SDKMessage
} from "@anthropic-ai/claude-agent-sdk"
import { isoTimestamp, type HarnessUsageLimits } from "@codevisor/api"
import { isRecord } from "./internal.js"
import type { ClaudeSession } from "./session.js"

/// A transient API failure can also arrive with NO structured error — the CLI
/// renders it as a plain assistant text message ending on a stop sequence
/// (observed: `API Error: 529 Overloaded …`). Match the CLI's error-line format
/// for 429 / 5xx (and a bare "overloaded"); 4xx client errors are NOT matched,
/// since those are permanent. Used only alongside a `stop_sequence` ending.
const API_ERROR_TEXT = /^\s*API Error:\s*(429|5\d\d)\b|^\s*overloaded\b/i

const claudeLimitWindow = (
  value: unknown,
  id: string,
  label: string,
  durationMinutes?: number
): HarnessUsageLimits["windows"][number] | undefined => {
  if (!isRecord(value) || typeof value.utilization !== "number") return undefined
  return {
    id,
    label,
    usedPercent: Math.max(0, Math.min(100, value.utilization)),
    ...(durationMinutes === undefined ? {} : { durationMinutes }),
    ...(typeof value.resets_at === "string" ? { resetsAt: value.resets_at } : {})
  }
}

export const claudeUsageLimitsFrom = (response: SDKControlGetUsageResponse): HarnessUsageLimits => {
  const limits = response.rate_limits
  const modelScoped = limits?.model_scoped ?? []
  const windows = [
    claudeLimitWindow(limits?.five_hour, "five-hour", "5-hour limit", 300),
    claudeLimitWindow(limits?.seven_day, "seven-day", "Weekly limit", 10_080),
    claudeLimitWindow(limits?.seven_day_oauth_apps, "oauth-apps", "Weekly OAuth apps", 10_080),
    ...(modelScoped.length > 0
      ? []
      : [
          claudeLimitWindow(limits?.seven_day_opus, "opus", "Weekly Opus", 10_080),
          claudeLimitWindow(limits?.seven_day_sonnet, "sonnet", "Weekly Sonnet", 10_080)
        ]),
    claudeLimitWindow(limits?.extra_usage, "extra-usage", "Extra usage")
  ].filter((window): window is NonNullable<typeof window> => window !== undefined)
  for (const [index, model] of modelScoped.entries()) {
    const window = claudeLimitWindow(
      model,
      `model-${index}`,
      `Weekly ${model.display_name}`,
      10_080
    )
    if (window !== undefined) windows.push(window)
  }
  return {
    fetchedAt: isoTimestamp(),
    harnessId: "claude-code",
    ...(response.subscription_type === null ? {} : { plan: response.subscription_type }),
    state: response.rate_limits_available && windows.length > 0 ? "available" : "unavailable",
    windows,
    ...(response.rate_limits_available && windows.length > 0
      ? {}
      : {
          detail:
            "Claude plan limits are unavailable for API-key, third-party, or insufficient-scope sessions."
        })
  }
}

/// Extracts the plain text from a CLI-generated assistant stop. Claude uses
/// this shape both for transient API errors and terminal usage-limit messages.
const stoppedAssistantText = (message: SDKMessage & { type: "assistant" }): string | undefined => {
  const inner = message.message as { stop_reason?: unknown; content?: unknown }
  if (inner.stop_reason !== "stop_sequence") return undefined
  const content = inner.content
  if (!Array.isArray(content)) return undefined
  const text = content
    .filter((block): block is Record<string, unknown> => isRecord(block) && block.type === "text")
    .map((block) => (typeof block.text === "string" ? block.text : ""))
    .join("")
    .trim()
  return text === "" ? undefined : text
}

const usageLimitText = (value: unknown): string | undefined => {
  if (typeof value !== "string") return undefined
  const text = value.trim()
  return USAGE_LIMIT_ERROR_PREFIXES.some((prefix) => text.startsWith(prefix)) ? text : undefined
}

export const detectUsageLimitMessage = (
  message: SDKMessage & { type: "assistant" }
): string | undefined => usageLimitText(stoppedAssistantText(message))

export const detectApiErrorMessage = (
  message: SDKMessage & { type: "assistant" }
): string | undefined => {
  const text = stoppedAssistantText(message)
  return text !== undefined && API_ERROR_TEXT.test(text) ? text : undefined
}

export const usageLimitTextFromResult = (
  message: SDKMessage & { type: "result" }
): string | undefined => {
  const raw = message as unknown as Record<string, unknown>
  const resultText = usageLimitText(raw.result)
  if (resultText !== undefined) return resultText
  if (!Array.isArray(raw.errors)) return undefined
  for (const error of raw.errors) {
    const text = usageLimitText(error)
    if (text !== undefined) return text
  }
  return undefined
}

export const rejectedUsageLimitDetail = (
  info: ClaudeSession["latestRateLimitInfo"]
): string | undefined => {
  if (info?.status !== "rejected") return undefined
  switch (info.overageDisabledReason) {
    case "out_of_credits":
      return info.canUserPurchaseCredits === true
        ? "You're out of Claude usage credits. Add credits in Claude to continue."
        : "Your Claude organization is out of usage credits. Contact your administrator."
    case "org_level_disabled":
    case "org_level_disabled_until":
    case "org_service_level_disabled":
      return "Your Claude organization has disabled additional usage. Contact your administrator."
    case "seat_tier_level_disabled":
      return "Your Claude plan doesn't include additional usage credits."
    case "member_level_disabled":
    case "member_zero_credit_limit":
    case "group_zero_credit_limit":
    case "seat_tier_zero_credit_limit":
      return "Your Claude usage allocation is unavailable. Contact your administrator."
    default:
      break
  }
  if (info.errorCode === "credits_required") {
    return "Claude usage credits are required to continue."
  }
  switch (info.rateLimitType) {
    case "five_hour":
      return "You've reached your 5-hour Claude usage limit. Try again after it resets."
    case "seven_day":
    case "seven_day_opus":
    case "seven_day_sonnet":
    case "seven_day_overage_included":
      return "You've reached your weekly Claude usage limit. Try again after it resets."
    default:
      return "You've reached your Claude usage limit. Try again after it resets."
  }
}

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

export const claudeContextWindowFrom = (
  value: unknown,
  latestModel: string | undefined,
  configuredModel: string
): number | undefined => {
  if (!isRecord(value)) return undefined
  const contextWindow = (entry: unknown): number | undefined => {
    if (!isRecord(entry)) return undefined
    const candidate = entry.contextWindow
    return typeof candidate === "number" && Number.isFinite(candidate) && candidate > 0
      ? candidate
      : undefined
  }
  for (const model of [latestModel, configuredModel]) {
    if (model === undefined || model === "") continue
    const matched = contextWindow(value[model])
    if (matched !== undefined) return matched
  }
  const available = new Set(
    Object.values(value)
      .map(contextWindow)
      .filter((size) => size !== undefined)
  )
  return available.size === 1 ? available.values().next().value : undefined
}

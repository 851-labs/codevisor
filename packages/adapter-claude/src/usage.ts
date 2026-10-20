import {
  USAGE_LIMIT_ERROR_PREFIXES,
  type SDKControlGetUsageResponse,
  type SDKMessage,
  type SDKRateLimitInfo
} from "@anthropic-ai/claude-agent-sdk"
import { epochResetTime } from "@codevisor/agent-runtime"
import { isoTimestamp, type HarnessUsageLimits } from "@codevisor/api"

import { isRecord, recordOf } from "./internal.js"
import type { ClaudeSession } from "./session.js"

const API_ERROR_TEXT = /^\s*API Error:\s*(429|5\d\d)\b|^\s*overloaded\b/i

const isoResetTime = (value: unknown): string | undefined => {
  if (typeof value !== "string") return undefined
  const time = Date.parse(value)
  return Number.isNaN(time) ? undefined : new Date(time).toISOString()
}

const claudeLimitWindow = (
  value: unknown,
  id: string,
  label: string,
  durationMinutes?: number
): HarnessUsageLimits["windows"][number] | undefined => {
  if (!isRecord(value) || typeof value.utilization !== "number") return undefined
  const resetsAt = isoResetTime(value.resets_at)
  return {
    id,
    label,
    usedPercent: Math.max(0, Math.min(100, value.utilization)),
    ...(durationMinutes === undefined ? {} : { durationMinutes }),
    ...(resetsAt === undefined ? {} : { resetsAt })
  }
}

const UNAVAILABLE_DETAIL =
  "Claude plan limits are unavailable for API-key, third-party, or insufficient-scope sessions."

const claudeWindowsFrom = (limits: unknown): HarnessUsageLimits["windows"] => {
  const record = isRecord(limits) ? limits : {}
  const modelScoped = Array.isArray(record.model_scoped) ? record.model_scoped.filter(isRecord) : []
  const extraUsage = isRecord(record.extra_usage) ? record.extra_usage : undefined
  const windows = [
    claudeLimitWindow(record.five_hour, "five-hour", "5-hour limit", 300),
    claudeLimitWindow(record.seven_day, "seven-day", "Weekly limit", 10_080),
    claudeLimitWindow(record.seven_day_oauth_apps, "oauth-apps", "Weekly OAuth apps", 10_080),
    ...(modelScoped.length > 0
      ? []
      : [
          claudeLimitWindow(record.seven_day_opus, "opus", "Weekly Opus", 10_080),
          claudeLimitWindow(record.seven_day_sonnet, "sonnet", "Weekly Sonnet", 10_080)
        ]),
    extraUsage?.is_enabled === false
      ? undefined
      : claudeLimitWindow(extraUsage, "extra-usage", "Extra usage")
  ].filter((window): window is NonNullable<typeof window> => window !== undefined)
  for (const [index, model] of modelScoped.entries()) {
    const window = claudeLimitWindow(
      model,
      `model-${index}`,
      `Weekly ${String(model.display_name)}`,
      10_080
    )
    if (window !== undefined) windows.push(window)
  }
  return windows
}

const claudeLimitsResult = (
  windows: HarnessUsageLimits["windows"],
  plan: string | null | undefined
): HarnessUsageLimits => ({
  fetchedAt: isoTimestamp(),
  harnessId: "claude-code",
  ...(plan === null || plan === undefined ? {} : { plan }),
  state: windows.length > 0 ? "available" : "unavailable",
  windows,
  ...(windows.length > 0 ? {} : { detail: UNAVAILABLE_DETAIL })
})

export const claudeUsageLimitsFrom = (response: SDKControlGetUsageResponse): HarnessUsageLimits =>
  claudeLimitsResult(
    response.rate_limits_available ? claudeWindowsFrom(response.rate_limits) : [],
    response.subscription_type
  )

const modelScopedFromLimits = (limits: unknown): ReadonlyArray<Record<string, unknown>> =>
  (Array.isArray(limits) ? limits : []).flatMap((limit) => {
    if (!isRecord(limit) || limit.kind !== "weekly_scoped") return []
    const scope = isRecord(limit.scope) ? limit.scope : undefined
    const model = isRecord(scope?.model) ? scope.model : undefined
    if (typeof model?.display_name !== "string") return []
    return [
      { display_name: model.display_name, utilization: limit.percent, resets_at: limit.resets_at }
    ]
  })

export const claudeOAuthUsageLimitsFrom = (body: unknown): HarnessUsageLimits => {
  const record = isRecord(body) ? body : {}
  return claudeLimitsResult(
    claudeWindowsFrom({ ...record, model_scoped: modelScopedFromLimits(record.limits) }),
    undefined
  )
}

const RATE_LIMIT_WINDOWS: Readonly<
  Record<string, { readonly id: string; readonly label: string; readonly durationMinutes: number }>
> = {
  five_hour: { id: "five-hour", label: "5-hour limit", durationMinutes: 300 },
  seven_day: { id: "seven-day", label: "Weekly limit", durationMinutes: 10_080 },
  seven_day_opus: { id: "opus", label: "Weekly Opus", durationMinutes: 10_080 },
  seven_day_sonnet: { id: "sonnet", label: "Weekly Sonnet", durationMinutes: 10_080 }
}

export const claudeRateLimitObservation = (
  info: SDKRateLimitInfo
): HarnessUsageLimits | undefined => {
  const window =
    info.rateLimitType === undefined ? undefined : RATE_LIMIT_WINDOWS[info.rateLimitType]
  if (window === undefined || info.utilization === undefined) return undefined
  return claudeLimitsResult(
    [
      {
        ...window,
        usedPercent: Math.max(0, Math.min(100, info.utilization * 100)),
        ...(info.resetsAt === undefined
          ? {}
          : { resetsAt: new Date(info.resetsAt * 1000).toISOString() })
      }
    ],
    undefined
  )
}

export const claudeUsageUnavailable = (error: unknown): HarnessUsageLimits => ({
  detail: error instanceof Error ? error.message : "Claude account usage limits are unavailable.",
  fetchedAt: isoTimestamp(),
  harnessId: "claude-code",
  state: "unavailable",
  windows: []
})

export const CLAUDE_OAUTH_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"

export const readClaudeOAuthUsage = async (
  accessToken: string,
  request: typeof fetch = fetch
): Promise<HarnessUsageLimits> => {
  const response = await request(CLAUDE_OAUTH_USAGE_URL, {
    headers: {
      accept: "application/json",
      authorization: `Bearer ${accessToken}`,
      "anthropic-beta": "oauth-2025-04-20"
    },
    signal: AbortSignal.timeout(10_000)
  })
  if (!response.ok) {
    await response.body?.cancel()
    throw new Error(`Claude usage request failed with HTTP ${response.status}`)
  }
  return claudeOAuthUsageLimitsFrom(await response.json())
}

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
  const raw = recordOf(message)
  const resultText = usageLimitText(raw.result)
  if (resultText !== undefined) return resultText
  if (!Array.isArray(raw.errors)) return undefined
  for (const error of raw.errors) {
    const text = usageLimitText(error)
    if (text !== undefined) return text
  }
  return undefined
}

export const rejectedUsageLimitReset = (
  info: ClaudeSession["latestRateLimitInfo"]
): Date | undefined => {
  if (info?.status !== "rejected") return undefined
  return epochResetTime(info.resetsAt, "seconds")
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

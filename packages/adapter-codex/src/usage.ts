import type { HarnessUsageLimits } from "@codevisor/api"
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

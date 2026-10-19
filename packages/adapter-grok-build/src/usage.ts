import type { AcpAgentConnection } from "@codevisor/adapter-acp"
import { adapterPromise, type AgentRuntimeError } from "@codevisor/agent-runtime"
import { isoTimestamp, type HarnessUsageLimits } from "@codevisor/api"
import { Effect } from "effect"

export const GROK_BILLING_METHOD = "_x.ai/billing"

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null

const record = (value: unknown): Record<string, unknown> => (isRecord(value) ? value : {})

const cents = (value: unknown): number | undefined => {
  const amount = record(value).val
  if (typeof amount === "number") return amount
  return typeof value === "object" && value !== null ? 0 : undefined
}

const isoTime = (value: unknown): string | undefined => {
  if (typeof value !== "string") return undefined
  const time = Date.parse(value)
  return Number.isNaN(time) ? undefined : new Date(time).toISOString()
}

const periodLabel = (type: unknown): string => {
  if (typeof type !== "string") return "Credits"
  if (type.endsWith("WEEKLY")) return "Weekly credits"
  if (type.endsWith("MONTHLY")) return "Monthly credits"
  return "Credits"
}

const usedPercent = (config: Record<string, unknown>): number | undefined => {
  if (typeof config.creditUsagePercent === "number") return config.creditUsagePercent
  const limit = cents(config.monthlyLimit)
  const used = cents(config.used)
  return limit !== undefined && limit > 0 && used !== undefined ? (used / limit) * 100 : undefined
}

export const grokUsageLimitsFrom = (response: unknown): HarnessUsageLimits => {
  const root = record(response)
  const config = record(root.config)
  const period = record(config.currentPeriod)
  const percent = usedPercent(config)
  const resetsAt = isoTime(period.end) ?? isoTime(config.billingPeriodEnd)
  const windows =
    percent === undefined
      ? []
      : [
          {
            id: "credits",
            label: periodLabel(period.type),
            usedPercent: Math.max(0, Math.min(100, percent)),
            ...(resetsAt === undefined ? {} : { resetsAt })
          }
        ]
  const prepaid = cents(config.prepaidBalance)
  const tier = root.subscriptionTier ?? root.subscription_tier
  const plan = typeof tier === "string" ? tier : undefined
  return {
    fetchedAt: isoTimestamp(),
    harnessId: "grok-build",
    ...(plan === undefined ? {} : { plan }),
    state: windows.length > 0 ? "available" : "unavailable",
    windows,
    ...(prepaid === undefined || prepaid <= 0
      ? {}
      : {
          credits: {
            hasCredits: true,
            unlimited: false,
            balance: `$${(prepaid / 100).toFixed(2)}`
          }
        }),
    ...(windows.length > 0 ? {} : { detail: "Grok Build did not report credit usage." })
  }
}

export const readGrokUsageLimits = (
  connection: AcpAgentConnection
): Effect.Effect<HarnessUsageLimits, AgentRuntimeError> => {
  const request = connection.extRequest
  if (request === undefined)
    return adapterPromise("readUsageLimits", () =>
      Promise.reject(new Error("Grok Build connection cannot send extension requests."))
    )
  const billing = () => request(GROK_BILLING_METHOD, {})
  return billing().pipe(
    Effect.catch(() =>
      connection.probeAuth(process.cwd()).pipe(
        Effect.andThen((probe) => {
          const external = probe.methods.find((method) => method.external === true)
          return external === undefined ? Effect.void : connection.authenticate(external.id)
        }),
        Effect.andThen(billing)
      )
    ),
    Effect.map(grokUsageLimitsFrom)
  )
}

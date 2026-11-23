import { isoTimestamp, isRecord, type HarnessUsageLimits } from "@codevisor/api"

export type CursorFetch = (url: string, init: RequestInit) => Promise<Response>

export interface CursorUsageSource {
  readonly accessToken: () => Promise<string | undefined>
  readonly fetch: CursorFetch
}

type UsageWindow = HarnessUsageLimits["windows"][number]

const dashboardUrl = "https://api2.cursor.sh/aiserver.v1.DashboardService"
const requestTimeoutMs = 10_000
const signedOutDetail = "Sign in to Cursor to see its usage."
const unreachableDetail = "Cursor usage is unavailable right now."

export const readCursorUsageLimits = async (
  source: CursorUsageSource
): Promise<HarnessUsageLimits> => {
  const token = await source.accessToken()
  if (token === undefined) return unavailable(signedOutDetail)

  const [usage, plan] = await Promise.all([
    dashboardCall(source.fetch, token, "GetCurrentPeriodUsage"),
    dashboardCall(source.fetch, token, "GetPlanInfo")
  ])
  if (usage.kind === "signedOut") return unavailable(signedOutDetail)
  if (usage.kind === "failed") return unavailable(unreachableDetail)
  return cursorUsageLimitsFrom(usage.body, plan.kind === "ok" ? plan.body : undefined)
}

export const cursorUsageLimitsFrom = (usage: unknown, plan: unknown): HarnessUsageLimits => {
  const planInfo = recordField(plan, "planInfo")
  const windows = usageWindows(usage, planInfo)
  const planName = stringField(planInfo, "planName")
  return {
    fetchedAt: isoTimestamp(),
    harnessId: "cursor",
    ...(planName === undefined ? {} : { plan: planName }),
    state: windows.length > 0 ? "available" : "unavailable",
    windows,
    ...(windows.length > 0 ? {} : { detail: "Cursor did not report plan usage." })
  }
}

const usageWindows = (
  usage: unknown,
  planInfo: Record<string, unknown> | undefined
): ReadonlyArray<UsageWindow> => {
  const planUsage = recordField(usage, "planUsage")
  const total = numberField(planUsage, "totalPercentUsed")
  if (total === undefined) return []

  const timing = windowTiming(usage, planInfo)
  const window = (id: string, label: string, usedPercent: number): UsageWindow => ({
    id,
    label,
    usedPercent,
    ...timing
  })
  const included = window("included", includedLabel(planInfo), total)
  const auto = numberField(planUsage, "autoPercentUsed")
  const api = numberField(planUsage, "apiPercentUsed")
  if (auto === undefined || api === undefined) return [included]
  return [included, window("auto", "Auto", auto), window("api", "API models", api)]
}

const windowTiming = (
  usage: unknown,
  planInfo: Record<string, unknown> | undefined
): Pick<UsageWindow, "durationMinutes" | "resetsAt"> => {
  const start = millisField(usage, "billingCycleStart")
  const end = millisField(usage, "billingCycleEnd")
  const resetsAt = millisField(planInfo, "includedUsageResetsAt") ?? end
  return {
    ...(start === undefined || end === undefined || end <= start
      ? {}
      : { durationMinutes: Math.round((end - start) / 60_000) }),
    ...(resetsAt === undefined ? {} : { resetsAt: new Date(resetsAt).toISOString() })
  }
}

const includedLabel = (planInfo: Record<string, unknown> | undefined): string => {
  switch (stringField(planInfo, "includedUsagePeriod")) {
    case "INCLUDED_USAGE_PERIOD_WEEKLY":
      return "Weekly usage"
    case "INCLUDED_USAGE_PERIOD_MONTHLY":
      return "Monthly usage"
    default:
      return "Included usage"
  }
}

type DashboardResult =
  | { readonly kind: "ok"; readonly body: unknown }
  | { readonly kind: "signedOut" }
  | { readonly kind: "failed" }

const dashboardCall = async (
  fetch: CursorFetch,
  token: string,
  method: string
): Promise<DashboardResult> => {
  try {
    const response = await fetch(`${dashboardUrl}/${method}`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
        "connect-protocol-version": "1"
      },
      body: "{}",
      signal: AbortSignal.timeout(requestTimeoutMs)
    })
    if (response.status === 401 || response.status === 403) return { kind: "signedOut" }
    if (!response.ok) return { kind: "failed" }
    return { kind: "ok", body: await response.json() }
  } catch {
    return { kind: "failed" }
  }
}

const unavailable = (detail: string): HarnessUsageLimits => ({
  detail,
  fetchedAt: isoTimestamp(),
  harnessId: "cursor",
  state: "unavailable",
  windows: []
})

const recordField = (value: unknown, field: string): Record<string, unknown> | undefined => {
  const nested = isRecord(value) ? value[field] : undefined
  return isRecord(nested) ? nested : undefined
}

const stringField = (value: unknown, field: string): string | undefined => {
  const raw = isRecord(value) ? value[field] : undefined
  return typeof raw === "string" && raw.length > 0 ? raw : undefined
}

const numberField = (value: unknown, field: string): number | undefined => {
  const raw = isRecord(value) ? value[field] : undefined
  return typeof raw === "number" && Number.isFinite(raw) ? raw : undefined
}

const millisField = (value: unknown, field: string): number | undefined => {
  const raw = isRecord(value) ? value[field] : undefined
  const millis = typeof raw === "string" ? Number(raw) : raw
  return typeof millis === "number" && Number.isFinite(millis) && millis > 0 ? millis : undefined
}

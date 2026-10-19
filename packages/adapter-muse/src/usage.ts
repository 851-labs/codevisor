import { usageLimitsObserved, type RuntimeEmit } from "@codevisor/agent-runtime"
import { isoTimestamp, type HarnessUsageLimits } from "@codevisor/api"

import type { MuseClient } from "./client.js"
import { record } from "./protocol.js"

const usageWindow = (value: unknown, id: string, label: string) => {
  const window = record(value)
  if (typeof window.usedPercent !== "number") return []
  const minutes =
    typeof window.windowDurationMins === "number" ? window.windowDurationMins : undefined
  return [
    {
      id,
      label: minutes === 300 ? "5-hour limit" : label,
      usedPercent: Math.max(0, Math.min(100, window.usedPercent)),
      ...(minutes === undefined ? {} : { durationMinutes: minutes }),
      ...(typeof window.resetsAtMs === "number"
        ? { resetsAt: new Date(window.resetsAtMs).toISOString() }
        : {})
    }
  ]
}

export const museUsageLimits = (response: unknown): HarnessUsageLimits => {
  const root = record(response)
  const usage = root.usage === undefined ? root : record(root.usage)
  const windows = [
    ...usageWindow(usage.window, "window", "Session limit"),
    ...usageWindow(usage.weekly, "weekly", "Weekly limit")
  ]
  return {
    fetchedAt: isoTimestamp(),
    harnessId: "muse-code",
    state: windows.length > 0 ? "available" : "unavailable",
    windows,
    ...(windows.length > 0
      ? {}
      : { detail: "Muse Code reports usage limits after its first reply." })
  }
}

export const observeMuseUsageLimits = async (
  client: Pick<MuseClient, "request">,
  sessionId: string,
  emit: RuntimeEmit
): Promise<void> => {
  let limits: HarnessUsageLimits
  try {
    limits = museUsageLimits(await client.request("usage/read", {}))
  } catch {
    return
  }
  if (limits.state === "available") await emit(usageLimitsObserved(sessionId, limits))
}

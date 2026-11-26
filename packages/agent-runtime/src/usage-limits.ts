import { isoTimestamp, type HarnessUsageLimits } from "@codevisor/api"

export const unavailableUsageLimits = (harnessId: string, detail: string): HarnessUsageLimits => ({
  detail,
  fetchedAt: isoTimestamp(),
  harnessId,
  state: "unavailable",
  windows: []
})

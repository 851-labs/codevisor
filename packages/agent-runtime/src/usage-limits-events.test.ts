import { describe, expect, it } from "vitest"

import { usageLimitsObservation, usageLimitsObserved } from "./usage-limits-events.js"

const limits = {
  fetchedAt: "2026-10-18T00:00:00.000Z",
  harnessId: "codex",
  state: "available" as const,
  windows: [{ id: "primary", label: "Weekly limit", usedPercent: 12 }]
}

describe("usage limits observations", () => {
  it("round-trips an adapter's observation and rejects other payloads", () => {
    expect(usageLimitsObservation(usageLimitsObserved("thread-1", limits, true).payload)).toEqual({
      limits,
      partial: true
    })
    expect(usageLimitsObservation(usageLimitsObserved("thread-1", limits).payload)).toEqual({
      limits,
      partial: false
    })
    expect(usageLimitsObservation({ sessionUpdate: "usage_limits_update" })).toBeUndefined()
    expect(usageLimitsObservation({ sessionUpdate: "usage_update", limits })).toBeUndefined()
    expect(usageLimitsObservation(undefined)).toBeUndefined()
  })
})

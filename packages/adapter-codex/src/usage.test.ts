import { describe, expect, it } from "vitest"
import { codexUsageLimitsFrom } from "./usage.js"

describe("Codex account usage", () => {
  it("normalizes app-server rate-limit windows", () => {
    const limits = codexUsageLimitsFrom({
      rateLimits: {
        planType: "plus",
        primary: { usedPercent: 37.4, windowDurationMins: 300, resetsAt: 1_800_000_000 },
        secondary: { usedPercent: 82, windowDurationMins: 10_080, resetsAt: 1_800_500_000 },
        credits: { hasCredits: true, unlimited: false, balance: "12.50" }
      }
    })

    expect(limits).toMatchObject({
      state: "available",
      plan: "plus",
      windows: [
        { id: "primary", label: "5-hour limit", usedPercent: 37.4 },
        { id: "secondary", label: "Weekly limit", usedPercent: 82 }
      ],
      credits: { hasCredits: true, unlimited: false, balance: "12.50" }
    })
  })
})

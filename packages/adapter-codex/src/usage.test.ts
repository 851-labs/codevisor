import { describe, expect, it } from "vitest"

import { codexSessionContextFrom, codexUsageLimitsFrom } from "./usage.js"

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

describe("Codex session context", () => {
  it("splits the latest request into new and cached input, output and reasoning", () => {
    expect(
      codexSessionContextFrom({
        last: {
          cachedInputTokens: 11_000,
          inputTokens: 18_000,
          outputTokens: 400,
          reasoningOutputTokens: 150,
          totalTokens: 18_400
        },
        modelContextWindow: 258_400
      })
    ).toEqual({
      categories: [
        { name: "Input", tokens: 7_000 },
        { name: "Cached input", tokens: 11_000 },
        { name: "Output", tokens: 250 },
        { name: "Reasoning", tokens: 150 },
        { name: "Free space", tokens: 240_000 }
      ],
      maxTokens: 258_400,
      mcpTools: [],
      totalTokens: 18_400
    })
  })

  it("clamps inconsistent counters and derives a missing total", () => {
    expect(
      codexSessionContextFrom({
        last: {
          cachedInputTokens: 50,
          inputTokens: 40,
          outputTokens: 10,
          reasoningOutputTokens: 30
        },
        modelContextWindow: 50
      })
    ).toEqual({
      categories: [
        { name: "Cached input", tokens: 40 },
        { name: "Reasoning", tokens: 10 }
      ],
      maxTokens: 50,
      mcpTools: [],
      totalTokens: 50
    })
  })

  it("has nothing to report without a context window or a latest request", () => {
    expect(codexSessionContextFrom(undefined)).toBeUndefined()
    expect(codexSessionContextFrom({ modelContextWindow: 100 })).toBeUndefined()
    expect(codexSessionContextFrom({ last: {}, modelContextWindow: Number.NaN })).toBeUndefined()
  })
})

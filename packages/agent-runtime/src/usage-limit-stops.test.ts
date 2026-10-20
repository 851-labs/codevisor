import { describe, expect, it } from "vitest"

import { epochResetTime, resetTimeIn, usageLimitStop } from "./usage-limit-stops.js"

const now = new Date("2026-10-20T12:00:00.000Z")

const resetAfter = (text: string): string | undefined => resetTimeIn(text, now)?.toISOString()

describe("usage limit stops", () => {
  it("marks a stop as a usage limit and carries its reset time when one is known", () => {
    expect(usageLimitStop("Usage limit reached")).toEqual({
      stopKind: "usageLimit",
      stopDetail: "Usage limit reached"
    })
    expect(usageLimitStop("Usage limit reached", now)).toEqual({
      stopKind: "usageLimit",
      stopDetail: "Usage limit reached",
      resetsAt: "2026-10-20T12:00:00.000Z"
    })
  })

  it("reads the relative reset times harnesses put in their limit messages", () => {
    expect(
      resetAfter(
        "RESOURCE_EXHAUSTED (code 429): Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 7m11s."
      )
    ).toBe("2026-10-20T12:07:11.000Z")
    expect(resetAfter("Your quota will reset after 19h14m47s.")).toBe("2026-10-21T07:14:47.000Z")
    expect(
      resetAfter("You have hit your ChatGPT usage limit (plus plan). Try again in ~142 min.")
    ).toBe("2026-10-20T14:22:00.000Z")
    expect(resetAfter("Quota exceeded.\nSuggested retry after 3600s.")).toBe(
      "2026-10-20T13:00:00.000Z"
    )
    expect(resetAfter("limit: 0\nPlease retry in 59.9s.")).toBe("2026-10-20T12:00:59.900Z")
    expect(resetAfter("Resets in 1d2h")).toBe("2026-10-21T14:00:00.000Z")
    expect(resetAfter("try again in 2 days, 3 hours and 5 minutes")).toBe(
      "2026-10-22T15:05:00.000Z"
    )
    expect(resetAfter("Retry in 250ms")).toBe("2026-10-20T12:00:00.250Z")
  })

  it("finds no reset time in messages without a usable duration", () => {
    expect(resetAfter("You've hit your usage limit. Try again later.")).toBeUndefined()
    expect(resetAfter("Resets in 0s")).toBeUndefined()
    expect(resetAfter("Rate limited by the API")).toBeUndefined()
  })

  it("reads epoch reset times in seconds or milliseconds and ignores missing ones", () => {
    expect(epochResetTime(1792400000, "seconds")?.toISOString()).toBe("2026-10-19T08:53:20.000Z")
    expect(epochResetTime(1792400000000, "milliseconds")?.toISOString()).toBe(
      "2026-10-19T08:53:20.000Z"
    )
    expect(epochResetTime(null, "seconds")).toBeUndefined()
    expect(epochResetTime(0, "seconds")).toBeUndefined()
    expect(epochResetTime(Number.NaN, "milliseconds")).toBeUndefined()
  })
})

import { describe, expect, it } from "vitest"

import { boundedMcpTimerDelay } from "./mcp-oauth.js"

describe("boundedMcpTimerDelay", () => {
  it("bounds long-lived OAuth refresh timers to Node's supported range", () => {
    expect(boundedMcpTimerDelay(2_591_232_324)).toBe(2_147_000_000)
    expect(boundedMcpTimerDelay(3_480_000)).toBe(3_480_000)
  })
})

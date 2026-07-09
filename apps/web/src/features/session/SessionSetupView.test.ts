import { describe, expect, it } from "vitest"

import { formatSetupSeconds, runningSetupTitle } from "./SessionSetupView"

describe("session setup labels", () => {
  it("formats running setup titles like SessionSetupView.swift", () => {
    expect(runningSetupTitle("Setting up worktree")).toBe("Setting up worktree…")
  })

  it("formats setup durations like SessionSetupView.swift", () => {
    expect(formatSetupSeconds(12)).toBe("12s")
    expect(formatSetupSeconds(64)).toBe("1m 4s")
  })
})

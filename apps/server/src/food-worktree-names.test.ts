import { describe, expect, it } from "vitest"
import { availableDevelopmentWorktreeName, foodWorktreeNames } from "./food-worktree-names.js"

describe("development food worktree names", () => {
  it("contains more than 500 unique food slugs", () => {
    expect(foodWorktreeNames.length).toBeGreaterThanOrEqual(500)
    expect(new Set(foodWorktreeNames).size).toBe(foodWorktreeNames.length)
    expect(foodWorktreeNames).toContain("chicken-fingers")
    expect(foodWorktreeNames.every((name) => /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(name))).toBe(true)
  })

  it("always appends four digits", () => {
    expect(
      availableDevelopmentWorktreeName(
        new Set(),
        () => 0,
        () => "8394"
      )
    ).toBe(`${foodWorktreeNames[0]}-8394`)
  })

  it("rerolls a complete food-and-number collision", () => {
    const first = `${foodWorktreeNames[0]}-8394`
    const digits = ["8394", "2718"]
    expect(
      availableDevelopmentWorktreeName(
        new Set([first]),
        () => 0,
        () => digits.shift() ?? "2718"
      )
    ).toBe(`${foodWorktreeNames[0]}-2718`)
  })

  it("falls back to a bounded scan when random retries keep colliding", () => {
    const first = foodWorktreeNames[0]!
    expect(
      availableDevelopmentWorktreeName(
        new Set([`${first}-0000`]),
        () => 0,
        () => "0"
      )
    ).toBe(`${first}-0001`)
  })

  it("moves to the next food after exhausting every suffix for one base", () => {
    const first = foodWorktreeNames[0]!
    const existing = new Set(
      Array.from({ length: 10_000 }, (_, index) => `${first}-${String(index).padStart(4, "0")}`)
    )

    expect(
      availableDevelopmentWorktreeName(
        existing,
        () => 0,
        () => "0"
      )
    ).toBe(`${foodWorktreeNames[1]}-0000`)
  })
})

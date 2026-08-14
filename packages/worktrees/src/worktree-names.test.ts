import { describe, expect, it } from "vitest"
import { availableProductionWorktreeName, productionFoodWorktreeNames } from "./worktree-names.js"

describe("production food worktree names", () => {
  it("contains at least 500 unique compact food words", () => {
    expect(productionFoodWorktreeNames.length).toBeGreaterThanOrEqual(500)
    expect(new Set(productionFoodWorktreeNames).size).toBe(productionFoodWorktreeNames.length)
    expect(productionFoodWorktreeNames).toContain("apple")
    expect(productionFoodWorktreeNames).toContain("ramen")
    expect(productionFoodWorktreeNames).toContain("saffron")
    expect(productionFoodWorktreeNames.every((name) => name.length <= 12)).toBe(true)
    expect(productionFoodWorktreeNames.every((name) => /^[a-z0-9]+$/.test(name))).toBe(true)
  })

  it("retries a random collision", () => {
    const values = [0, 0.5]
    const candidate = availableProductionWorktreeName(
      new Set([productionFoodWorktreeNames[0]!]),
      () => values.shift() ?? 0.5
    )

    expect(candidate).toBe(
      productionFoodWorktreeNames[Math.floor(productionFoodWorktreeNames.length / 2)]
    )
  })

  it("scans the entire pool after random retries are exhausted", () => {
    const candidate = availableProductionWorktreeName(
      new Set([productionFoodWorktreeNames[0]!]),
      () => 0
    )

    expect(candidate).toBe(productionFoodWorktreeNames[1])
  })

  it("uses a random ID only after every base name is occupied", () => {
    const firstName = productionFoodWorktreeNames[0]!
    const existing = new Set<string>(productionFoodWorktreeNames)
    existing.add(`${firstName}-deadbeef`)
    const ids = ["deadbeef", "cafebabe"]

    expect(
      availableProductionWorktreeName(
        existing,
        () => 0,
        () => ids.shift() ?? "unused"
      )
    ).toBe(`${firstName}-cafebabe`)
  })

  it("generates a default random ID after every base name is occupied", () => {
    const candidate = availableProductionWorktreeName(new Set(productionFoodWorktreeNames), () => 0)

    expect(candidate).toMatch(new RegExp(`^${productionFoodWorktreeNames[0]!}-[0-9a-f]{8}$`))
  })

  it("fails after every production base and random ID collides", () => {
    const firstName = productionFoodWorktreeNames[0]!
    const existing = new Set<string>(productionFoodWorktreeNames)
    existing.add(`${firstName}-deadbeef`)

    expect(() =>
      availableProductionWorktreeName(
        existing,
        () => 0,
        () => "deadbeef"
      )
    ).toThrow("Unable to allocate a unique production worktree name")
  })
})

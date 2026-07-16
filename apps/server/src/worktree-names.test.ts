import { describe, expect, it } from "vitest"
import { availableGeneratedWorktreeName, generatedWorktreeNames } from "./worktree-names.js"

describe("generated worktree names", () => {
  it("contains 588 unique short surname slugs", () => {
    expect(generatedWorktreeNames).toHaveLength(588)
    expect(new Set(generatedWorktreeNames).size).toBe(588)
    expect(generatedWorktreeNames.every((name) => name.length <= 12)).toBe(true)
    expect(generatedWorktreeNames.every((name) => /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(name))).toBe(
      true
    )
  })

  it("retries a random collision", () => {
    const values = [0, 0.5]
    const candidate = availableGeneratedWorktreeName(
      new Set([generatedWorktreeNames[0]]),
      () => values.shift() ?? 0.5
    )

    expect(candidate).toBe(generatedWorktreeNames[Math.floor(generatedWorktreeNames.length / 2)])
  })

  it("scans the entire pool after random retries are exhausted", () => {
    const candidate = availableGeneratedWorktreeName(new Set([generatedWorktreeNames[0]]), () => 0)

    expect(candidate).toBe(generatedWorktreeNames[1])
  })

  it("uses a random ID only after every base name is occupied", () => {
    const firstName = generatedWorktreeNames[0]
    const existing = new Set<string>(generatedWorktreeNames)
    existing.add(`${firstName}-deadbeef`)
    const ids = ["deadbeef", "cafebabe"]

    expect(
      availableGeneratedWorktreeName(
        existing,
        () => 0,
        () => ids.shift() ?? "unused"
      )
    ).toBe(`${firstName}-cafebabe`)
  })
})

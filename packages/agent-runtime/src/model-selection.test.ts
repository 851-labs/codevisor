import { describe, expect, it } from "vitest"

import {
  findKnownModel,
  highestThinkingLevel,
  offeredConfigValues,
  placeConfigValue,
  sanitizeModelValue
} from "./model-selection.js"

describe("model-selection", () => {
  it("strips ANSI, control characters, and trailing SGR fragments", () => {
    expect(sanitizeModelValue("claude-fable-5\u001b[1m")).toBe("claude-fable-5")
    expect(sanitizeModelValue("gpt\u0000-5")).toBe("gpt-5")
    expect(sanitizeModelValue("  model[1;2m")).toBe("model")
  })

  it("matches models by exact value, then by sanitized value", () => {
    const models = [{ value: "claude-fable-5" }, { value: "sonnet" }]
    expect(findKnownModel(models, "sonnet")?.value).toBe("sonnet")
    expect(findKnownModel(models, "claude-fable-5\u001b[1m")?.value).toBe("claude-fable-5")
    expect(findKnownModel(models, "unknown")).toBeUndefined()
  })

  it("picks the highest known thinking level and ignores unknown ranks", () => {
    expect(highestThinkingLevel([])).toBeUndefined()
    expect(highestThinkingLevel(["low", "high", "medium"])).toBe("high")
    expect(highestThinkingLevel(["mystery", "low"])).toBe("low")
    expect(highestThinkingLevel(["high", "mystery"])).toBe("high")
    expect(highestThinkingLevel(["mystery-a", "mystery-b"])).toBe("mystery-b")
  })

  it("flattens grouped config options and places requested values", () => {
    const flat = {
      id: "model",
      name: "Model",
      type: "select" as const,
      currentValue: "sonnet",
      options: [
        { name: "Sonnet", value: "sonnet" },
        { name: "Opus", value: "opus" }
      ]
    }
    const grouped = {
      id: "model",
      name: "Model",
      type: "select" as const,
      currentValue: "opus",
      options: [
        {
          group: "main",
          name: "Main",
          options: [{ name: "Opus", value: "opus" }]
        }
      ]
    }
    expect([...offeredConfigValues(flat)].toSorted()).toEqual(["opus", "sonnet"])
    expect([...offeredConfigValues(grouped)].toSorted()).toEqual(["opus"])
    expect(placeConfigValue(flat, "opus", undefined)).toBe("opus")
    expect(placeConfigValue(flat, "missing", undefined)).toBeUndefined()
    expect(
      placeConfigValue(flat, "old-opus", (_option, value) =>
        value === "old-opus" ? "opus" : undefined
      )
    ).toBe("opus")
    expect(
      placeConfigValue(flat, "old-haiku", (_option, value) =>
        value === "old-haiku" ? "haiku" : undefined
      )
    ).toBeUndefined()
  })
})

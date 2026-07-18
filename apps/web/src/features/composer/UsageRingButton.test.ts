/* Tests for the temporarily disabled usage gauge and popover.
import { describe, expect, it } from "vitest"

import {
  abbreviateUsageValue,
  formatUsageCost,
  formatUsageTokens,
  shouldShowCreditsBalance,
  usageAccessibilityLabel,
  usageContextPercent,
  usageFraction
} from "./UsageRingButton"

describe("usage ring formatting", () => {
  it("abbreviates token counts like UsageFormatting.abbreviate", () => {
    expect(abbreviateUsageValue(999)).toBe("999")
    expect(abbreviateUsageValue(1_000)).toBe("1.0K")
    expect(abbreviateUsageValue(62_000)).toBe("62.0K")
    expect(abbreviateUsageValue(1_000_000)).toBe("1.0M")
  })

  it("formats token rows like the macOS usage popover", () => {
    expect(formatUsageTokens(62_000, 128_000)).toBe("62.0K / 128.0K tokens")
    expect(formatUsageTokens(62_000, undefined)).toBe("62.0K tokens")
    expect(formatUsageTokens(62_000, 0)).toBe("62.0K tokens")
  })

  it("formats cost with extra precision below one unit", () => {
    expect(formatUsageCost(0.12345, "USD")).toContain("0.1235")
    expect(formatUsageCost(1.42, "USD")).toContain("1.42")
  })

  it("hides zero credit balances", () => {
    expect(shouldShowCreditsBalance("0")).toBe(false)
    expect(shouldShowCreditsBalance("0.00")).toBe(false)
    expect(shouldShowCreditsBalance("$0.00")).toBe(false)
    expect(shouldShowCreditsBalance("12.50")).toBe(true)
  })

  it("builds the accessibility label from the same metrics as macOS", () => {
    expect(
      usageAccessibilityLabel({
        used: 62_000,
        size: 128_000,
        costAmount: 1.42,
        costCurrency: "USD"
      })
    ).toContain("Cost")
    expect(
      usageAccessibilityLabel({
        used: 62_000,
        size: 128_000,
        costAmount: 1.42,
        costCurrency: "USD"
      })
    ).toContain("62.0K / 128.0K tokens")
    expect(usageAccessibilityLabel({ used: 62_000 })).not.toContain("percent")
  })

  it("clamps context usage like UsageRingButton.fraction", () => {
    expect(usageFraction({ used: 62_000, size: 128_000 })).toBeCloseTo(0.484375)
    expect(usageFraction({ used: 180_000, size: 128_000 })).toBe(1)
    expect(usageFraction({ used: 62_000 })).toBe(0)
    expect(usageContextPercent({ used: 62_000, size: 128_000 })).toBe(48)
  })
})
*/

export {}

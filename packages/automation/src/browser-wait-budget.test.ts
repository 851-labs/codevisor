import { expect, it } from "vitest"

import { defaultWaitMs, maxWaitMs, waitBudget } from "./browser-wait-budget.js"

it("uses the default when no timeout is given, and the caller's own default when it has one", () => {
  expect(waitBudget(undefined)).toBe(defaultWaitMs)
  expect(waitBudget(null)).toBe(defaultWaitMs)
  expect(waitBudget(undefined, 0)).toBe(0)
})

it("honours any timeout up to the limit", () => {
  expect(waitBudget(0)).toBe(0)
  expect(waitBudget(45_000)).toBe(45_000)
  expect(waitBudget(maxWaitMs)).toBe(maxWaitMs)
})

it("refuses a timeout beyond the limit instead of shortening it", () => {
  expect(() => waitBudget(maxWaitMs + 1)).toThrow(
    "timeoutMs can be at most 120000 (2 minutes), and 120001 was asked for. Wait on a condition, or wait again."
  )
})

it.each([-1, Number.NaN, "soon", Number.POSITIVE_INFINITY])("refuses %s as a timeout", (value) => {
  expect(() => waitBudget(value)).toThrow("timeoutMs must be 0 or more milliseconds")
})

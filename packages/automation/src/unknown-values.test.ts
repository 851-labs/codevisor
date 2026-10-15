import { describe, expect, it } from "vitest"

import {
  expectArray,
  expectBoolean,
  expectNumber,
  expectRecord,
  expectString,
  isPlainRecord,
  isRecord,
  isStringArray,
  optionalString,
  recordOrEmpty,
  recordOrUndefined,
  recordsIn
} from "./unknown-values.js"

describe("unknown value narrowing", () => {
  it("separates records, plain records, and everything else", () => {
    expect([{}, [], null, "x"].map(isRecord)).toEqual([true, true, false, false])
    expect([{}, [], null].map(isPlainRecord)).toEqual([true, false, false])
    expect(recordOrEmpty({ a: 1 })).toEqual({ a: 1 })
    expect(recordOrEmpty(7)).toEqual({})
    expect(recordOrUndefined({ a: 1 })).toEqual({ a: 1 })
    expect(recordOrUndefined(undefined)).toBeUndefined()
    expect(recordsIn([{ a: 1 }, null])).toEqual([{ a: 1 }, {}])
    expect(recordsIn("x")).toEqual([])
  })

  it("accepts only string arrays and optional strings", () => {
    expect([["a"], ["a", 1], "a"].map(isStringArray)).toEqual([true, false, false])
    expect(optionalString("a")).toBe("a")
    expect(optionalString(1)).toBeUndefined()
  })

  it("returns expected shapes and names the source of anything else", () => {
    expect(expectString("a", "Title")).toBe("a")
    expect(expectBoolean(false, "Flag")).toBe(false)
    expect(expectNumber(0, "Count")).toBe(0)
    expect(expectRecord({ a: 1 }, "State")).toEqual({ a: 1 })
    expect(expectArray([1], "Items")).toEqual([1])
    expect(() => expectString(1, "Title")).toThrow("Title returned a non-string value")
    expect(() => expectBoolean("true", "Flag")).toThrow("Flag returned a non-boolean value")
    expect(() => expectNumber("1", "Count")).toThrow("Count returned a non-number value")
    expect(() => expectRecord([], "State")).toThrow("State returned a non-object value")
    expect(() => expectArray({}, "Items")).toThrow("Items returned a non-array value")
  })
})

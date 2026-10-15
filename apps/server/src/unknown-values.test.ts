import { describe, expect, it } from "vitest"

import { asRecord, errorCode, field, isRecord, recordField, stringField } from "./unknown-values.js"

describe("unknown values", () => {
  it("treats only non-array objects as records", () => {
    expect(isRecord({ a: 1 })).toBe(true)
    expect(isRecord([1])).toBe(false)
    expect(isRecord(null)).toBe(false)
    expect(isRecord("text")).toBe(false)
  })

  it("reads fields only from records", () => {
    expect(field({ a: 1 }, "a")).toBe(1)
    expect(field("text", "length")).toBeUndefined()
    expect(stringField({ a: "x" }, "a")).toBe("x")
    expect(stringField({ a: 1 }, "a")).toBeUndefined()
    expect(recordField({ a: { b: 1 } }, "a")).toEqual({ b: 1 })
    expect(recordField({ a: [1] }, "a")).toEqual({})
    expect(asRecord({ a: 1 })).toEqual({ a: 1 })
    expect(asRecord(null)).toEqual({})
  })

  it("reads the code of thrown values", () => {
    expect(errorCode(Object.assign(new Error("gone"), { code: "ENOENT" }))).toBe("ENOENT")
    expect(errorCode("boom")).toBeUndefined()
  })
})

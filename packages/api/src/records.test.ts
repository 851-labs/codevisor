import { describe, expect, it } from "vitest"

import { isPlainRecord, isRecord } from "./index.js"

describe("record guards", () => {
  it("accepts any non-null object as a record", () => {
    expect(isRecord({ a: 1 })).toBe(true)
    expect(isRecord([1])).toBe(true)
    expect(isRecord(null)).toBe(false)
    expect(isRecord("text")).toBe(false)
  })

  it("rejects arrays as plain records", () => {
    expect(isPlainRecord({ a: 1 })).toBe(true)
    expect(isPlainRecord([1])).toBe(false)
    expect(isPlainRecord(null)).toBe(false)
  })
})

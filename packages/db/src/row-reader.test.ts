import { describe, expect, it } from "vitest"

import { blob, integer, literal, nullable, optional, real, rowReader, text } from "./row-reader.js"

const rows = rowReader({
  id: text,
  count: integer,
  ratio: nullable(real),
  state: literal("open", "closed"),
  note: optional(text),
  data: nullable(blob)
})

describe("row reader", () => {
  it("returns rows whose columns match without copying them", () => {
    const row = { id: "a", count: 1, ratio: null, state: "open", data: Buffer.from("x"), extra: 1 }
    expect(rows.one(row)).toBe(row)
    expect(rows.maybe(row)).toBe(row)
    expect(rows.all([row, { ...row, ratio: 0.5, note: "n", data: null }])).toHaveLength(2)
    expect(rows.is(row)).toBe(true)
  })

  it("treats a missing row as undefined only when the caller allows it", () => {
    expect(rows.maybe(undefined)).toBeUndefined()
    expect(() => rows.one(undefined)).toThrow("Expected a database row")
    expect(rows.is(null)).toBe(false)
  })

  it("names the first column whose value has the wrong type", () => {
    const row = { id: "a", count: 1, ratio: null, state: "open", data: null }
    expect(() => rows.one({ ...row, count: "1" })).toThrow("column count")
    expect(() => rows.one({ ...row, state: "pending" })).toThrow("column state")
    expect(() => rows.one({ ...row, note: 1 })).toThrow("column note")
    expect(() => rows.one({ ...row, data: "x" })).toThrow("column data")
    expect(() => rows.all([row, { ...row, id: null }])).toThrow("column id")
  })
})

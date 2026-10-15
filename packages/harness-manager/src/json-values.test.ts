import { describe, expect, it } from "vitest"

import {
  errnoCode,
  optionalBoolean,
  optionalNumber,
  parseJsonRecord,
  recordArray,
  recordOrEmpty
} from "./json-values.js"

describe("JSON value guards", () => {
  it("keeps only values of the expected shape", () => {
    expect(recordOrEmpty([1])).toEqual({})
    expect(recordOrEmpty({ a: 1 })).toEqual({ a: 1 })
    expect(recordArray("nope")).toEqual([])
    expect(recordArray([{ a: 1 }, null, [], "x"])).toEqual([{ a: 1 }])
    expect(optionalBoolean("true")).toBeUndefined()
    expect(optionalBoolean(false)).toBe(false)
    expect(optionalNumber("1")).toBeUndefined()
    expect(optionalNumber(1)).toBe(1)
  })

  it("reads error codes without trusting the thrown value", () => {
    expect(errnoCode(Object.assign(new Error("missing"), { code: "ENOENT" }))).toBe("ENOENT")
    expect(errnoCode(new Error("plain"))).toBeUndefined()
    expect(errnoCode("ENOENT")).toBeUndefined()
    expect(errnoCode(null)).toBeUndefined()
  })

  it("parses only JSON objects as records", () => {
    expect(parseJsonRecord('{"a":1}')).toEqual({ a: 1 })
    expect(() => parseJsonRecord("[1]")).toThrow("Expected a JSON object")
    expect(() => parseJsonRecord("null")).toThrow("Expected a JSON object")
  })
})

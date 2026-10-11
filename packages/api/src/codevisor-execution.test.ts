import { describe, expect, it } from "vitest"

import { canonicalExecutionArgs } from "./codevisor-execution.js"

describe("canonicalExecutionArgs", () => {
  it("matches regardless of key order at any depth", () => {
    const expected = '{"code":"c","description":"d","x":{"a":[{"y":2,"z":1}],"b":1}}'
    expect(
      canonicalExecutionArgs({ description: "d", code: "c", x: { b: 1, a: [{ z: 1, y: 2 }] } })
    ).toBe(expected)
    expect(
      canonicalExecutionArgs({ x: { a: [{ y: 2, z: 1 }], b: 1 }, code: "c", description: "d" })
    ).toBe(expected)
  })

  it("still yields JSON for arguments JSON cannot represent", () => {
    expect(canonicalExecutionArgs(undefined)).toBe("null")
  })
})

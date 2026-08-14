import { describe, expect, it } from "vitest"
import { textToolResult } from "./automation-provider.js"

describe("textToolResult", () => {
  it("returns successful and failed MCP text results", () => {
    expect(textToolResult("ok")).toEqual({
      content: [{ type: "text", text: "ok" }]
    })
    expect(textToolResult("failed", true)).toEqual({
      content: [{ type: "text", text: "failed" }],
      isError: true
    })
  })
})

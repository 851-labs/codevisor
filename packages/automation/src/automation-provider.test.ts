import { describe, expect, it } from "vitest"

import { browserResultPageUrl, textToolResult } from "./automation-provider.js"

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

describe("browserResultPageUrl", () => {
  it("reads the page a page action reports, and nothing else", () => {
    expect(
      browserResultPageUrl(textToolResult('Page URL: https://linear.app/x\n{"action":"navigate"}'))
    ).toBe("https://linear.app/x")
    expect(browserResultPageUrl(textToolResult('{"tabs":[]}'))).toBeUndefined()
    expect(
      browserResultPageUrl(textToolResult("Page URL: https://a.example", true))
    ).toBeUndefined()
    expect(browserResultPageUrl({ content: [] })).toBeUndefined()
    expect(
      browserResultPageUrl({ content: [{ type: "image", data: "", mimeType: "image/png" }] })
    ).toBeUndefined()
  })
})

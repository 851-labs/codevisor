import { describe, expect, it } from "vitest"

import { textToolResult } from "./automation-provider.js"
import { jsonResult } from "./browser-cdp-engine.js"
import { labelBrowserResult } from "./browser-result-label.js"

const label = { backend: "builtin", host: "Codevisor on Mac Studio" } as const

describe("browser result labels", () => {
  it("adds where the call ran to tab results only", () => {
    expect(labelBrowserResult("tabs", jsonResult({ tabs: [] }), label)).toEqual(
      jsonResult({ tabs: [], browser: label })
    )
    const navigated = jsonResult({ url: "https://example.com/" })
    expect(labelBrowserResult("navigate", navigated, label)).toBe(navigated)
  })

  it("leaves errors, plain text, lists, and multi-part results alone", () => {
    const unchanged = [
      jsonResult({ tabs: [] }, true),
      textToolResult("not json"),
      jsonResult([1, 2]),
      { content: [...jsonResult({}).content, ...jsonResult({}).content] }
    ]
    for (const result of unchanged) expect(labelBrowserResult("tabs", result, label)).toBe(result)
  })
})

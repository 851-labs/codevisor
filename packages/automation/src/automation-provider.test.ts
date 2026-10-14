import { describe, expect, it } from "vitest"

import { browserResultPageUrl, computerResultApp, textToolResult } from "./automation-provider.js"

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

describe("computerResultApp", () => {
  it("reads the app an observation resolved, and nothing else", () => {
    const observation = (resolvedApp: unknown) =>
      textToolResult(JSON.stringify({ snapshotId: "s", resolvedApp, text: "..." }))
    expect(
      computerResultApp(
        observation({
          id: "com.apple.Music",
          name: "Music",
          path: "/System/Applications/Music.app"
        })
      )
    ).toEqual({
      bundleId: "com.apple.Music",
      name: "Music",
      path: "/System/Applications/Music.app"
    })
    expect(computerResultApp(observation({ id: "com.apple.Notes" }))).toEqual({
      bundleId: "com.apple.Notes"
    })
    expect(computerResultApp(observation({ id: "" }))).toBeUndefined()
    expect(computerResultApp(observation(null))).toBeUndefined()
    expect(
      computerResultApp(textToolResult('{"delivered":true,"app":"com.apple.Music"}'))
    ).toBeUndefined()
    expect(computerResultApp(textToolResult('"resolvedApp" in plain text'))).toBeUndefined()
    expect(
      computerResultApp(textToolResult(JSON.stringify({ resolvedApp: { id: "x.y" } }), true))
    ).toBeUndefined()
    expect(
      computerResultApp({ content: [{ type: "image", data: "", mimeType: "image/png" }] })
    ).toBeUndefined()
  })
})

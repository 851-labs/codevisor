import { describe, expect, it } from "vitest"

import { isPublicHost, pageIconCandidates } from "./tool-icon-candidates.js"

describe("page icon candidates", () => {
  it("prefers sized icons near 64px, then SVGs, small rasters, unsized icons, and touch icons", () => {
    const page = `
      <link rel="apple-touch-icon" href="/touch.png">
      <link rel="icon" href="/plain.ico">
      <link rel="icon" sizes="16x16" href="/16.png">
      <link rel="icon" type="image/svg+xml" href="/logo.svg">
      <link rel="shortcut icon" sizes="32x32 192x192" href="/192.png">
      <link rel=icon sizes=96x96 href=/96.png?a=1&amp;b=2>
      <link rel="mask-icon" href="/mask.svg">
      <link rel="icon" href="javascript:alert(1)">
      <link rel="icon" href="http://[bad">
      <link rel="icon">
      <link rel="stylesheet" href="/style.css">
      <link href="/no-rel.png">
      <link rel="icon" sizes="large" href="/unsized-too.png">
      <link rel="icon" href="/96.png?a=1&b=2">`
    expect(pageIconCandidates(page, "https://example.com/start")).toEqual([
      "https://example.com/96.png?a=1&b=2",
      "https://example.com/logo.svg",
      "https://example.com/192.png",
      "https://example.com/16.png",
      "https://example.com/plain.ico",
      "https://example.com/unsized-too.png",
      "https://example.com/touch.png"
    ])
  })

  it("chooses the variant a page declares for the appearance", () => {
    const page = `
      <link rel="icon" href="/light.png" sizes="64x64" media="(prefers-color-scheme: light)">
      <link rel="icon" href="/dark.png" sizes="64x64" media="(prefers-color-scheme: dark)">
      <link rel="icon" href="data:image/png;base64,AAAA" sizes="any">`
    expect(pageIconCandidates(page, "https://example.com/", "light")[0]).toBe(
      "https://example.com/light.png"
    )
    expect(pageIconCandidates(page, "https://example.com/", "dark")).toEqual([
      "https://example.com/dark.png",
      "data:image/png;base64,AAAA",
      "https://example.com/light.png"
    ])
  })
})

describe("public hosts", () => {
  it("accepts dotted internet names and refuses local, private, and IP hosts", () => {
    expect(isPublicHost("www.emojis.com")).toBe(true)
    expect(isPublicHost("Linear.App")).toBe(true)
    for (const host of [
      "localhost",
      "intranet",
      "192.168.1.20",
      "[::1]",
      "::1",
      "printer.local",
      "app.localhost",
      "jira.corp",
      "svc.internal",
      "site.test"
    ]) {
      expect(isPublicHost(host)).toBe(false)
    }
  })
})

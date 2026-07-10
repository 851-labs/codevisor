import { describe, expect, it } from "vitest"

import { isSupportedExternalUrl } from "./ExternalLink"

describe("external links", () => {
  it("allows the schemes supported by the native link surface", () => {
    expect(isSupportedExternalUrl("https://example.com/docs")).toBe(true)
    expect(isSupportedExternalUrl("http://localhost:3000")).toBe(true)
    expect(isSupportedExternalUrl("mailto:hello@example.com")).toBe(true)
    expect(isSupportedExternalUrl("tel:+14155550100")).toBe(true)
  })

  it("does not pass relative or executable URLs to the Tauri opener", () => {
    expect(isSupportedExternalUrl("/internal/storybook")).toBe(false)
    expect(isSupportedExternalUrl("javascript:alert(1)")).toBe(false)
    expect(isSupportedExternalUrl("not a url")).toBe(false)
  })
})

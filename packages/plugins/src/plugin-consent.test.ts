import { describe, expect, it } from "vitest"
import { pluginConsentKey } from "./plugin-consent.js"

describe("plugin consent identity", () => {
  it("identifies a source without exposing it and distinguishes publishers, repos, and subplugins", () => {
    const key = pluginConsentKey("acme.notes", "https://github.com/acme/notes.git")
    expect(key).toMatch(/^[a-f0-9]{64}$/)
    expect(pluginConsentKey("acme.notes", "https://github.com/acme/notes.git", "")).toBe(key)
    expect(pluginConsentKey("acme.other", "https://github.com/acme/notes.git")).not.toBe(key)
    expect(pluginConsentKey("acme.notes", "https://github.com/other/notes.git")).not.toBe(key)
    expect(pluginConsentKey("acme.notes", "https://github.com/acme/notes.git", "nested")).not.toBe(
      key
    )
  })
})

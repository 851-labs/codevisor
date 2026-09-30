import { describe, expect, it } from "vitest"

import { withoutEnv } from "./types.js"

describe("withoutEnv", () => {
  const parent = { HOME: "/Users/me", GROK_AUTH: "inherited", XAI_API_KEY: "sk-parent" }

  it("preserves environment values when nothing is asked to be removed", () => {
    expect(withoutEnv(parent, undefined)).toEqual(parent)
    expect(withoutEnv(parent, [])).toEqual(parent)
  })

  it("drops the listed variables from a copy and leaves the original untouched", () => {
    const result = withoutEnv(parent, ["GROK_AUTH", "XAI_API_KEY", "NOT_PRESENT"])
    expect(result).toEqual({ HOME: "/Users/me" })
    expect(result).not.toHaveProperty("GROK_AUTH")
    expect(parent.GROK_AUTH).toBe("inherited")
  })
})

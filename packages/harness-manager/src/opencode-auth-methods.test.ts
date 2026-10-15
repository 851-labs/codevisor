import { describe, expect, it } from "vitest"

import {
  methodValues,
  parseAuthorization,
  parseProviderList,
  parseUpstreamMethods
} from "./opencode-auth-methods.js"

describe("OpenCode auth responses", () => {
  it("drops catalog entries that lack an id or a name", () => {
    expect(
      parseProviderList({
        all: [{ id: "openai", name: "OpenAI" }, { id: "nameless" }, { name: 1 }, "x"]
      })
    ).toEqual([{ id: "openai", name: "OpenAI" }])
    expect(parseProviderList(null)).toEqual([])
  })

  it("reads auth methods field by field and falls back to an API key for malformed entries", () => {
    const methods = parseUpstreamMethods({
      openai: [
        {
          type: "oauth",
          label: 7,
          prompts: [{ type: "text", key: "plan", message: "Plan", when: "always" }, null]
        }
      ],
      broken: "not a list"
    })
    expect(methodValues(methods.openai)).toEqual([
      {
        id: "0",
        type: "oauth",
        label: "Provider account",
        prompts: [{ type: "text", key: "plan", message: "Plan", options: [] }]
      }
    ])
    expect(methodValues(methods.broken)).toEqual([
      { id: "0", type: "api", label: "API key", prompts: [] }
    ])
    expect(parseUpstreamMethods([])).toEqual({})
  })

  it("keeps only string authorization fields", () => {
    expect(parseAuthorization({ url: "https://auth.test", method: 1 })).toEqual({
      url: "https://auth.test",
      method: undefined,
      instructions: undefined
    })
  })
})

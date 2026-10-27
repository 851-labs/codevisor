import { createHmac } from "node:crypto"

import { describe, expect, it } from "vitest"

import { makePluginAppTokens, sameScope } from "./plugin-app-tokens.js"

const secret = Buffer.alloc(32, 7)
const view = { kind: "view", viewId: "view-1" } as const

const signed = (payload: unknown): string => {
  const encoded = Buffer.from(JSON.stringify(payload)).toString("base64url")
  return `${encoded}.${createHmac("sha256", secret).update(encoded).digest("base64url")}`
}

describe("plugin app tokens", () => {
  it("verifies its own tokens until they expire", () => {
    let now = 1_000
    const tokens = makePluginAppTokens(secret, () => now)
    const issued = tokens.issue(view, 60_000)

    expect(issued.expiresAt).toBe(new Date(61_000).toISOString())
    now = 60_999
    expect(tokens.verify(issued.token)).toEqual(view)
    now = 61_000
    expect(tokens.verify(issued.token)).toBeUndefined()
  })

  it("rejects tampered, foreign, and malformed tokens", () => {
    const tokens = makePluginAppTokens(secret, () => 0)
    const issued = tokens.issue(view, 60_000)
    const [payload] = issued.token.split(".")

    expect(tokens.verify(`${payload}.forged`)).toBeUndefined()
    expect(makePluginAppTokens(Buffer.alloc(32, 8)).verify(issued.token)).toBeUndefined()
    expect(tokens.verify("no-signature")).toBeUndefined()
    expect(tokens.verify(`${issued.token}.extra`)).toBeUndefined()
    expect(tokens.verify(signed({ scope: { kind: "file" }, expiresAt: 10 }))).toBeUndefined()
    expect(tokens.verify(signed("not claims"))).toBeUndefined()
    expect(
      tokens.verify(
        `e30.${createHmac("sha256", secret).update("e30").digest("base64url")}`.replace("e30", "!")
      )
    ).toBeUndefined()
  })

  it("compares scopes by value", () => {
    expect(sameScope(view, { kind: "view", viewId: "view-1" })).toBe(true)
    expect(sameScope(view, { kind: "pane", serverId: "s", paneType: "p" })).toBe(false)
  })
})

import { describe, expect, it } from "vitest"

import { McpSignInNeedsMachine, signInFailure } from "./mcp-sign-in-failure.js"

describe("MCP sign-in failures", () => {
  it("words a sign-in server the machine can't reach", () => {
    const unreachable = new TypeError("fetch failed", { cause: { code: "ECONNREFUSED" } })

    const failure = signInFailure(unreachable, "https://mcp.example.test/mcp")

    if (!(failure instanceof Error)) throw new Error("Expected an Error")
    expect(failure.message).toBe(
      "Couldn't reach mcp.example.test. Check your network connection and try again."
    )
    expect(failure.cause).toBe(unreachable)
  })

  it("keeps every other failure as it is", () => {
    const rejected = new Error("Invalid client")
    const typeError = new TypeError("Invalid URL")

    expect(signInFailure(rejected, "https://mcp.example.test/mcp")).toBe(rejected)
    expect(signInFailure(typeError, "https://mcp.example.test/mcp")).toBe(typeError)
  })

  it("says why a sign-in started on another device can only finish on the plugin's machine", () => {
    const reasons = ["ownClient", "cloudRefused"] as const

    const messages = reasons.map((reason) => new McpSignInNeedsMachine(reason, "Tracker").message)

    expect(messages).toEqual([
      "Tracker uses your own OAuth client, which only sends sign-in back to the machine it runs on. Sign in from Codevisor on that machine.",
      "Tracker won't send sign-in back through Codevisor Cloud, so it can only finish on the machine it runs on. Sign in from Codevisor on that machine."
    ])
  })
})

import { describe, expect, it } from "vitest"

import { AgentRuntimeError, runtimeError } from "./types.js"

describe("runtimeError", () => {
  it("remembers when a harness reported that it needs a new sign-in", () => {
    const signedOut = [
      Object.assign(new Error("Authentication required"), { code: -32000 }),
      Object.assign(new Error("not signed in"), { kind: "authRequired" }),
      Object.assign(new Error("Sign in again"), { reason: "reauthenticate" }),
      Object.assign(new Error("signed out"), { reason: "revoked" }),
      new AgentRuntimeError({ authRequired: true, message: "Internal error", operation: "prompt" })
    ]
    for (const cause of signedOut) {
      expect(runtimeError("prompt", cause).authRequired).toBe(true)
    }
  })

  it("leaves other failures unmarked, even when they mention signing in", () => {
    const others = [
      new Error("Please sign in"),
      Object.assign(new Error("Internal error"), { code: -32603 }),
      Object.assign(new Error("offline"), { reason: "offline" }),
      "boom"
    ]
    for (const cause of others) {
      expect(runtimeError("prompt", cause).authRequired).toBeUndefined()
    }
  })
  it("remembers when a harness couldn't find the conversation it was asked to resume", () => {
    const missing = Object.assign(
      new Error("Claude Code couldn't find this chat's saved conversation."),
      {
        conversationMissing: true
      }
    )

    expect(runtimeError("loadSession", missing).conversationMissing).toBe(true)
    expect(runtimeError("loadSession", new Error("offline")).conversationMissing).toBeUndefined()
  })
})

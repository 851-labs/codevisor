import type { SharedOAuthHarness, SharedTokenBundle } from "@codevisor/harness-manager"
import { describe, expect, it } from "vitest"

import { sharedAccountFor, sharedAccountLabel } from "./shared-account-store.js"

const bundle = (
  fields: Pick<SharedTokenBundle, "harnessId"> & Partial<SharedTokenBundle>
): SharedTokenBundle => ({
  subject: "s",
  accessToken: "token-1234",
  expiresAt: 1,
  ownership: "managed",
  ...fields
})

describe("shared account names", () => {
  it("keeps a name the user chose, but not one Codevisor made up", () => {
    const signIn = bundle({ harnessId: "codex", email: "me@example.com" })
    expect(sharedAccountLabel(signIn, "Work")).toBe("Work")
    for (const madeUp of [undefined, "", "New Account", "Account 2b8f8d"])
      expect(sharedAccountLabel(signIn, madeUp)).toBe("me@example.com")
    expect(sharedAccountLabel(signIn, "Account two")).toBe("Account two")
  })

  it("names an account without an email for what it is", () => {
    expect(sharedAccountLabel(bundle({ harnessId: "antigravity", authMethod: "apiKey" }))).toBe(
      "Gemini API key ••••1234"
    )
    expect(
      (
        [
          ["antigravity", undefined],
          ["codex", "apiKey"],
          ["muse-code", undefined],
          ["claude-code", "apiKey"]
        ] satisfies ReadonlyArray<readonly [SharedOAuthHarness, "apiKey" | undefined]>
      ).map(([harnessId, authMethod]) =>
        sharedAccountLabel(bundle({ harnessId, ...(authMethod ? { authMethod } : {}) }))
      )
    ).toEqual(["Google", "ChatGPT", "Meta", "Claude"])
  })

  it("never turns an MCP server sign-in into a harness account", () => {
    const credential = { id: "credential-0123456789", key: "k".repeat(43) }
    expect(() =>
      sharedAccountFor(bundle({ harnessId: "mcp" }), credential, undefined, "machine")
    ).toThrow("An MCP sign-in is not a harness account")
  })
})

import { describe, expect, it } from "vitest"

import { sharedAccountLabel } from "./shared-account-store.js"

const bundle = (fields: Record<string, unknown>) =>
  ({
    subject: "s",
    accessToken: "token-1234",
    expiresAt: 1,
    ownership: "managed",
    ...fields
  }) as never

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
      [
        ["antigravity", undefined],
        ["codex", "apiKey"],
        ["muse-code", undefined],
        ["claude-code", "apiKey"]
      ].map(([harnessId, authMethod]) =>
        sharedAccountLabel(bundle({ harnessId, ...(authMethod ? { authMethod } : {}) }))
      )
    ).toEqual(["Google", "ChatGPT", "Meta", "Claude"])
  })
})

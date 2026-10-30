import { describe, expect, it } from "vitest"

import { isSharedTokenBundle, type SharedTokenBundle } from "./shared-credential-types.js"

const complete: SharedTokenBundle = {
  authMethod: "apiKey",
  harnessId: "pi",
  subject: "user",
  organizationId: "workspace",
  email: "user@example.test",
  accessToken: "access",
  refreshToken: "refresh",
  idToken: "id",
  expiresAt: 1,
  planType: "pro",
  scopes: ["user:inference"],
  providerId: "anthropic",
  credential: { projectId: "project" },
  ownership: "managed"
}

describe("shared token bundles", () => {
  it("accepts minimal and fully populated bundles", () => {
    expect(isSharedTokenBundle(complete)).toBe(true)
    expect(
      isSharedTokenBundle({
        harnessId: "codex",
        subject: "user",
        accessToken: "access",
        expiresAt: 1,
        ownership: "external"
      })
    ).toBe(true)
    expect(isSharedTokenBundle({ ...complete, harnessId: "mcp" })).toBe(true)
    expect(isSharedTokenBundle({ ...complete, harnessId: "plugin" })).toBe(true)
  })

  it.each([
    null,
    [],
    { ...complete, harnessId: "unknown" },
    { ...complete, subject: 1 },
    { ...complete, accessToken: undefined },
    { ...complete, expiresAt: Number.NaN },
    { ...complete, ownership: "shared" },
    { ...complete, authMethod: "oauth" },
    { ...complete, email: 1 },
    { ...complete, scopes: "user:inference" },
    { ...complete, scopes: [1] },
    { ...complete, credential: "project" }
  ])("rejects a bundle with a malformed field (%#)", (value) => {
    expect(isSharedTokenBundle(value)).toBe(false)
  })
})

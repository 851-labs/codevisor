import type { Provider, OAuthCredential } from "@earendil-works/pi-ai"
import { describe, expect, it, vi } from "vitest"

import type { SharedTokenBundle } from "./shared-credential-types.js"
import { refreshSharedOAuth } from "./shared-oauth-providers.js"
import {
  parseProviderOAuth,
  providerCredential,
  providerOAuthSupported,
  providerTokenEndpoint,
  refreshProviderOAuth
} from "./shared-provider-oauth.js"

const jwt = (value: unknown) =>
  `header.${Buffer.from(JSON.stringify(value)).toString("base64url")}.signature`
const credential = {
  type: "oauth",
  access: jwt({ sub: "user", email: "user@example.test" }),
  refresh: "refresh",
  expires: 3_600_000,
  accountId: "workspace"
}
const bundle = (): SharedTokenBundle =>
  parseProviderOAuth("opencode", "openai", credential, "managed")!
const grok = {
  auth_mode: "oidc",
  key: "access",
  refresh_token: "refresh",
  expires_at: "2030-01-01T00:00:00Z",
  oidc_issuer: "https://auth.x.ai",
  oidc_client_id: "b1a00492-073a-47ea-816f-4c329264a828",
  user_id: "grok-user"
}

describe("shared provider OAuth contracts", () => {
  it("enrolls inspected native integrations and leaves unknown plugins local", () => {
    expect(providerOAuthSupported("pi", "anthropic")).toBe(true)
    expect(providerOAuthSupported("pi", "custom")).toBe(false)
    expect(providerOAuthSupported("grok-build", "xai")).toBe(true)
    expect(providerOAuthSupported("grok-build", "custom")).toBe(false)
    expect(providerOAuthSupported("opencode", "xai")).toBe(true)
    expect(providerOAuthSupported("opencode", "custom")).toBe(false)
    expect(providerTokenEndpoint("xai")).toBe("https://auth.x.ai/oauth2/token")
    expect(providerTokenEndpoint("custom")).toBeUndefined()
  })
  it("preserves provider metadata while keeping refresh tokens out of external mirrors and runtime profiles", () => {
    const managed = bundle()
    expect(managed).toMatchObject({
      subject: "user",
      organizationId: "workspace",
      email: "user@example.test",
      refreshToken: "refresh"
    })
    const mirrored = parseProviderOAuth("opencode", "openai", credential, "external")!
    expect(mirrored.refreshToken).toBeUndefined()
    expect(mirrored.credential).not.toHaveProperty("refresh")
    expect(providerCredential(managed, "codevisor:handle")).toEqual({
      ...credential,
      refresh: "codevisor:handle"
    })
  })
  it("recognizes OpenAI and Grok identities without equating distinct workspaces", () => {
    const identity = {
      "https://api.openai.com/auth": { chatgpt_user_id: "person", chatgpt_account_id: "team" }
    }
    expect(
      parseProviderOAuth(
        "opencode",
        "openai",
        { ...credential, accountId: undefined, access: jwt(identity) },
        "managed"
      )
    ).toMatchObject({ subject: "person", organizationId: "team" })
    const token = parseProviderOAuth(
      "grok-build",
      "xai",
      { ...grok, organization_id: "company", email: "g@example.test" },
      "managed"
    )!
    expect(token).toMatchObject({
      subject: "grok-user",
      organizationId: "company",
      email: "g@example.test",
      refreshToken: "refresh"
    })
    expect(token.credential).not.toHaveProperty("refresh_token")
    expect(parseProviderOAuth("grok-build", "xai", grok, "external")!.refreshToken).toBeUndefined()
  })
  it("preserves Grok device identity and distinguishes team consent from personal consent", () => {
    const device = {
      ...grok,
      key: jwt({ principal_id: "team" }),
      id_token: jwt({ sub: "person", email: "person@example.test" })
    }
    expect(parseProviderOAuth("grok-build", "xai", device, "managed")).toMatchObject({
      subject: "person",
      email: "person@example.test",
      organizationId: "team"
    })
    expect(
      parseProviderOAuth(
        "grok-build",
        "xai",
        { ...device, key: jwt({ principalId: "other-team" }) },
        "managed"
      )?.organizationId
    ).toBe("other-team")
  })
  it("keeps opaque grants distinct and shares durable Copilot tokens without pretending they rotate", () => {
    const a = parseProviderOAuth(
      "pi",
      "anthropic",
      { ...credential, access: "opaque", accountId: undefined },
      "managed"
    )!
    const b = parseProviderOAuth(
      "pi",
      "anthropic",
      { ...credential, access: "opaque", refresh: "other" },
      "managed"
    )!
    expect(a.subject).not.toBe(b.subject)
    expect(a.email).toBeUndefined()
    expect(a.organizationId).toBeUndefined()
    const copilot = parseProviderOAuth(
      "opencode",
      "github-copilot",
      { type: "oauth", refresh: "github-token", access: "", expires: 0 },
      "external"
    )!
    expect(copilot).toMatchObject({
      accessToken: "github-token",
      ownership: "managed",
      expiresAt: Number.MAX_SAFE_INTEGER
    })
    expect(copilot.refreshToken).toBeUndefined()
    expect(providerCredential(copilot, "unused").refresh).toBe("github-token")
    expect(
      providerCredential({ ...a, providerId: undefined } as unknown as SharedTokenBundle, "handle")
        .refresh
    ).toBe("handle")
  })
  it.each([
    null,
    [],
    { type: "api" },
    { ...credential, access: "" },
    { ...credential, refresh: "" },
    { ...credential, refresh: "codevisor:handle" },
    { ...credential, expires: NaN },
    { ...credential, expires: "123" },
    { ...credential, access: "a." }
  ])("rejects malformed native credentials where required fields are absent", (value) => {
    const parsed = parseProviderOAuth("opencode", "openai", value, "managed")
    // An opaque bearer is valid; its stable refresh grant supplies identity.
    if ((value as typeof credential)?.access === "a.") expect(parsed?.subject).toMatch(/^grant:/)
    else expect(parsed).toBeUndefined()
  })
  it("rejects uninspected plugins and enterprise issuers without sending them a fleet token", () => {
    expect(parseProviderOAuth("opencode", "custom", credential, "managed")).toBeUndefined()
    for (const value of [
      { ...grok, auth_mode: "web_login" },
      { ...grok, oidc_issuer: "https://idp.example.test" },
      { ...grok, oidc_client_id: "other" },
      { ...grok, expires_at: "invalid" },
      { ...grok, key: "" }
    ])
      expect(parseProviderOAuth("grok-build", "xai", value, "managed")).toBeUndefined()
  })
  it("shares Grok API keys without refreshing them or exposing the key as account identity", () => {
    const parsed = parseProviderOAuth(
      "grok-build",
      "xai",
      { auth_mode: "api_key", key: "api-key" },
      "external"
    )!
    expect(parsed).toMatchObject({
      authMethod: "apiKey",
      accessToken: "api-key",
      expiresAt: Number.MAX_SAFE_INTEGER,
      ownership: "managed"
    })
    expect(parsed.subject).toMatch(/^key:/)
    expect(parsed.subject).not.toContain("api-key")
    expect(parsed.refreshToken).toBeUndefined()
    expect(
      parseProviderOAuth("grok-build", "xai", { auth_mode: "api_key", key: "" }, "managed")
    ).toBeUndefined()
  })
  it("uses Pi's own provider refresher and preserves provider-specific fields", async () => {
    const refresh = vi.fn(async (_credential: OAuthCredential, _signal?: AbortSignal) => ({
      type: "oauth" as const,
      access: "fresh",
      refresh: "rotated",
      expires: 9_000_000,
      projectId: "project"
    }))
    const providers = [{ id: "anthropic", auth: { oauth: { refresh } } }] as unknown as Provider[]
    const token = parseProviderOAuth("pi", "anthropic", credential, "managed")!
    const next = await refreshProviderOAuth(token, fetch, 0, providers)
    expect(next).toMatchObject({
      accessToken: "fresh",
      refreshToken: "rotated",
      subject: token.subject,
      credential: { projectId: "project" }
    })
    expect(refresh.mock.calls[0]?.[0]).toEqual(credential)
    expect(providerCredential(next, "codevisor:handle").refresh).toBe("codevisor:handle")
    await expect(refreshProviderOAuth(token, fetch, 0, [])).rejects.toThrow("Sign in again")
    for (const invalid of [{ access: "" }, { refresh: "" }, { expires: NaN }]) {
      refresh.mockResolvedValueOnce({
        type: "oauth",
        access: "fresh",
        refresh: "rotated",
        expires: 9_000_000,
        projectId: "project",
        ...invalid
      })
      await expect(refreshProviderOAuth(token, fetch, 0, providers)).rejects.toThrow(
        "Sign in again"
      )
    }
  })
  it.each(["openai", "xai"])(
    "rotates %s through its original OAuth client and keeps a refresh token omitted by the provider",
    async (providerId) => {
      const request = vi.fn(async () =>
        Response.json({ access_token: "fresh", expires_in: 3600, id_token: "id" })
      )
      const token = { ...bundle(), providerId }
      const next = await refreshSharedOAuth(token, request as unknown as typeof fetch, 1000)
      expect(next).toMatchObject({
        accessToken: "fresh",
        expiresAt: 3_601_000,
        refreshToken: "refresh",
        idToken: "id"
      })
      const [url, init] = request.mock.calls[0] as unknown as [string, RequestInit]
      expect(url).toBe(providerTokenEndpoint(providerId))
      expect(new URLSearchParams(String(init.body)).get("refresh_token")).toBe("refresh")
      expect(init.redirect).toBe("error")
      expect(new URLSearchParams(String(init.body)).get("client_id")).toBe(
        providerId === "openai"
          ? "app_EMoamEEZ73f0CkXaXp7hrann"
          : "b1a00492-073a-47ea-816f-4c329264a828"
      )
    }
  )
  it("persists rotated refresh tokens and rejects failed or malformed exchanges without retries", async () => {
    const request = vi.fn(async () =>
      Response.json({ access_token: "fresh", refresh_token: "rotated", expires_in: 3600 })
    )
    expect(await refreshProviderOAuth(bundle(), request as unknown as typeof fetch)).toMatchObject({
      refreshToken: "rotated"
    })
    for (const value of [
      null,
      {},
      { access_token: "fresh" },
      { access_token: "fresh", expires_in: -1 },
      { access_token: "fresh", expires_in: "123" }
    ]) {
      request.mockResolvedValueOnce(Response.json(value))
      await expect(
        refreshProviderOAuth(bundle(), request as unknown as typeof fetch, 0)
      ).rejects.toThrow("Sign in again")
    }
    request.mockResolvedValueOnce(new Response(null, { status: 401 }))
    await expect(
      refreshProviderOAuth(bundle(), request as unknown as typeof fetch, 0)
    ).rejects.toThrow("Sign in again")
    for (const token of [
      { ...bundle(), refreshToken: undefined },
      { ...bundle(), providerId: undefined },
      { ...bundle(), ownership: "external" },
      { ...bundle(), providerId: "custom" }
    ])
      await expect(refreshProviderOAuth(token as unknown as SharedTokenBundle)).rejects.toThrow(
        "Sign in again"
      )
    expect(request).toHaveBeenCalledTimes(7)
  })
})

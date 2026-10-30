import { describe, expect, it, vi } from "vitest"

import {
  mcpCredentialFailure,
  McpRefreshRejected,
  McpRefreshUnavailable,
  mcpTokenBundle,
  refreshOAuthGrant
} from "./mcp-oauth-grant.js"

const grant = {
  authorizationServerUrl: "https://auth.tracker.example",
  authorizationServerMetadata: {
    issuer: "https://auth.tracker.example",
    authorization_endpoint: "https://auth.tracker.example/authorize",
    token_endpoint: "https://auth.tracker.example/oauth/token",
    response_types_supported: ["code"]
  },
  resource: new URL("https://tracker.example/mcp"),
  client: { client_id: "registered-client" }
}

const signedIn = mcpTokenBundle(
  "https://tracker.example/mcp",
  grant,
  {
    access_token: "access-1",
    refresh_token: "refresh-1",
    token_type: "Bearer",
    expires_in: 3600,
    scope: "read write"
  },
  1_000
)

const respond =
  (status: number, body: unknown, contentType = "application/json") =>
  async () =>
    new Response(typeof body === "string" ? body : JSON.stringify(body), {
      status,
      headers: { "content-type": contentType }
    })

const connectionFailure = (code: string) => async () => {
  throw new TypeError("fetch failed", { cause: Object.assign(new Error(code), { code }) })
}

describe("MCP OAuth grants", () => {
  it("seals what any machine needs to refresh the grant with its own client", () => {
    expect(signedIn).toEqual({
      harnessId: "mcp",
      subject: "https://tracker.example/mcp",
      accessToken: "access-1",
      refreshToken: "refresh-1",
      expiresAt: 3_601_000,
      scopes: ["read", "write"],
      ownership: "managed",
      credential: {
        authorizationServerUrl: "https://auth.tracker.example",
        authorizationServerMetadata: grant.authorizationServerMetadata,
        resource: "https://tracker.example/mcp",
        client: { client_id: "registered-client" }
      }
    })
    expect(
      mcpTokenBundle(
        "https://bare.example/mcp",
        { authorizationServerUrl: "https://auth.bare.example", client: { client_id: "c" } },
        { access_token: "a", token_type: "Bearer" },
        0
      )
    ).toEqual({
      harnessId: "mcp",
      subject: "https://bare.example/mcp",
      accessToken: "a",
      expiresAt: Number.MAX_SAFE_INTEGER,
      ownership: "managed",
      credential: {
        authorizationServerUrl: "https://auth.bare.example",
        client: { client_id: "c" }
      }
    })
  })

  it("rotates through the grant's token endpoint with its client and resource", async () => {
    const requests: Array<{ url: string; redirect?: RequestRedirect; body: string }> = []
    const request: typeof fetch = async (url, init) => {
      requests.push({
        url: url instanceof Request ? url.url : url.toString(),
        ...(init?.redirect === undefined ? {} : { redirect: init.redirect }),
        body: init?.body instanceof URLSearchParams ? init.body.toString() : ""
      })
      return respond(200, {
        access_token: "access-2",
        refresh_token: "refresh-2",
        token_type: "Bearer",
        expires_in: 60,
        scope: "read"
      })()
    }

    const rotated = await refreshOAuthGrant(signedIn, { fetch: request, now: () => 5_000 })

    expect(rotated).toMatchObject({
      accessToken: "access-2",
      refreshToken: "refresh-2",
      expiresAt: 65_000,
      scopes: ["read"],
      credential: signedIn.credential
    })
    expect(requests).toHaveLength(1)
    expect(requests[0]?.url).toBe("https://auth.tracker.example/oauth/token")
    expect(requests[0]?.redirect).toBe("error")
    expect(Object.fromEntries(new URLSearchParams(requests[0]?.body))).toEqual({
      grant_type: "refresh_token",
      refresh_token: "refresh-1",
      client_id: "registered-client",
      resource: "https://tracker.example/mcp"
    })
  })

  it("keeps the refresh token and an open expiry when the server returns neither", async () => {
    const { authorizationServerMetadata: _metadata, resource: _resource, ...minimal } = grant
    const bundle = mcpTokenBundle(
      "https://tracker.example/mcp",
      minimal,
      { access_token: "a", refresh_token: "r", token_type: "Bearer" },
      0
    )
    const urls: Array<string> = []
    const request: typeof fetch = async (url) => {
      urls.push(url instanceof Request ? url.url : url.toString())
      return respond(200, { access_token: "b", token_type: "Bearer" })()
    }
    expect(await refreshOAuthGrant(bundle, { fetch: request })).toMatchObject({
      accessToken: "b",
      refreshToken: "r",
      expiresAt: Number.MAX_SAFE_INTEGER
    })
    expect(urls).toEqual(["https://auth.tracker.example/token"])
  })

  it("uses the global fetch by default", async () => {
    vi.stubGlobal("fetch", vi.fn(respond(400, { error: "invalid_grant" })))
    try {
      await expect(refreshOAuthGrant(signedIn)).rejects.toBeInstanceOf(McpRefreshRejected)
    } finally {
      vi.unstubAllGlobals()
    }
  })

  it.each([
    ["invalid_grant", respond(400, { error: "invalid_grant" })],
    ["invalid_client", respond(401, { error: "invalid_client" })]
  ])("reports %s as a rejected grant", async (code, request) => {
    const failure = await refreshOAuthGrant(signedIn, { fetch: request }).catch((cause) => cause)
    expect(failure).toBeInstanceOf(McpRefreshRejected)
    expect(failure).toMatchObject({ code })
  })

  it("rejects a bundle that cannot be refreshed", async () => {
    const { refreshToken: _refresh, ...withoutRefresh } = signedIn
    for (const bundle of [withoutRefresh, { ...signedIn, credential: { client: {} } }]) {
      await expect(refreshOAuthGrant(bundle)).rejects.toMatchObject({ code: "missing_grant" })
    }
  })

  it.each([
    ["server_error", respond(503, "<html>down</html>", "text/html")],
    ["temporarily_unavailable", respond(503, { error: "temporarily_unavailable" })],
    ["too_many_requests", respond(429, { error: "too_many_requests" })],
    ["ECONNREFUSED", connectionFailure("ECONNREFUSED")],
    ["ENOTFOUND", connectionFailure("ENOTFOUND")]
  ])("reports %s as unavailable, leaving the refresh token unspent", async (detail, request) => {
    const failure = await refreshOAuthGrant(signedIn, { fetch: request }).catch((cause) => cause)
    expect(failure).toBeInstanceOf(McpRefreshUnavailable)
    expect(failure).toMatchObject({ detail })
  })

  it.each([
    ["a dropped connection", connectionFailure("ECONNRESET")],
    [
      "an unexplained fetch failure",
      async () => {
        throw new TypeError("fetch failed")
      }
    ],
    ["an unreadable success", respond(200, { unexpected: true })]
  ])("treats %s as ambiguous because the token may have rotated", async (_case, request) => {
    const failure = await refreshOAuthGrant(signedIn, { fetch: request }).catch((cause) => cause)
    expect(failure).toBeInstanceOf(Error)
    expect(failure).not.toBeInstanceOf(McpRefreshUnavailable)
    expect(failure).not.toBeInstanceOf(McpRefreshRejected)
  })

  it("classifies vault failures", () => {
    expect(mcpCredentialFailure({ reason: "revoked" })).toBe("revoked")
    expect(mcpCredentialFailure({ reason: "busy" })).toBe("busy")
    expect(mcpCredentialFailure({ reason: "reauthenticate", status: 400 })).toBe("rejected")
    expect(mcpCredentialFailure({ reason: "reauthenticate" })).toBe("reauthorize")
    expect(mcpCredentialFailure({ reason: "offline" })).toBe("unavailable")
    expect(mcpCredentialFailure(new Error("socket hang up"))).toBe("unavailable")
    expect(mcpCredentialFailure("socket hang up")).toBe("unavailable")
  })
})

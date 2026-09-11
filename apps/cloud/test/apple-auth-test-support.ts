import { env } from "cloudflare:test"
import { exportJWK, exportPKCS8, generateKeyPair, jwtVerify, SignJWT, type JWTPayload } from "jose"
import { afterEach, beforeAll, beforeEach, expect, vi } from "vitest"
import type { CloudEnv } from "../src/env.js"
import worker from "../src/index.js"
import { BASE } from "./cloud-test-support.js"

export const issuer = "https://appleid.apple.com"
export const clientId = "com.example.codevisor.cloud"
export let appleEnv: CloudEnv
export let signingKey: CryptoKey
export let clientPublicKey: CryptoKey
let jwks: { keys: Record<string, unknown>[] }
export let codes: Map<string, string>
export let revoked: string[]
let revokeFails = false
export const setRevokeFails = (value: boolean) => {
  revokeFails = value
}
export const nativeClientId = "com.example.codevisor.ios"
export let subject: string
let relayEmail: string

beforeAll(async () => {
  const signing = await generateKeyPair("RS256")
  const client = await generateKeyPair("ES256", { extractable: true })
  signingKey = signing.privateKey
  clientPublicKey = client.publicKey
  jwks = {
    keys: [{ ...(await exportJWK(signing.publicKey)), kid: "test-apple-key", alg: "RS256" }]
  }
  appleEnv = {
    ...env,
    APPLE_CLIENT_ID: clientId,
    APPLE_NATIVE_CLIENT_ID: nativeClientId,
    APPLE_TEAM_ID: "TESTTEAM01",
    APPLE_KEY_ID: "TESTKEY001",
    APPLE_PRIVATE_KEY: await exportPKCS8(client.privateKey)
  }
})

beforeEach(({ task }) => {
  subject = `apple:${task.name}`
  relayEmail = `${task.name.replace(/[^a-z]/gi, "-")}@privaterelay.appleid.com`
  codes = new Map()
  revoked = []
  revokeFails = false
  // All Apple traffic is owned by this fake. An unexpected network request
  // fails immediately; no developer credentials or live Apple accounts are used.
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init)
    if (request.url === `${issuer}/auth/keys`) return Response.json(jwks)
    const body = new URLSearchParams(await request.text())
    if (request.url === `${issuer}/auth/token` || request.url === `${issuer}/auth/revoke`) {
      const audience = body.get("client_id")!
      expect([clientId, nativeClientId]).toContain(audience)
      await jwtVerify(body.get("client_secret")!, clientPublicKey, {
        issuer: "TESTTEAM01",
        subject: audience,
        audience: issuer,
        algorithms: ["ES256"]
      })
      if (request.url.endsWith("/revoke")) {
        if (revokeFails) return new Response("unavailable", { status: 503 })
        revoked.push(body.get("token")!)
        return new Response(null, { status: 200 })
      }
      expect(body.get("redirect_uri")).toBe(
        audience === clientId ? `${BASE}/api/auth/callback/apple` : null
      )
      expect(body.get("grant_type")).toBe("authorization_code")
      const code = body.get("code")!
      const token = codes.get(code)
      codes.delete(code)
      if (!token) return Response.json({ error: "invalid_grant" }, { status: 400 })
      return Response.json({
        id_token: token,
        access_token: "apple-access",
        refresh_token: "apple-refresh",
        expires_in: 3600,
        token_type: "Bearer"
      })
    }
    throw new Error(`Unexpected outbound request: ${request.url}`)
  })
})

afterEach(() => vi.restoreAllMocks())

export const identityToken = async (claims: JWTPayload = {}, audience = clientId) =>
  new SignJWT({
    email: relayEmail,
    email_verified: "true",
    ...claims
  })
    .setProtectedHeader({ alg: "RS256", kid: "test-apple-key" })
    .setIssuer(issuer)
    .setAudience(audience)
    .setSubject(subject)
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(signingKey)

export class Browser {
  private cookies = new Map<string, string>()

  async request(
    path: string,
    body?: Record<string, unknown>,
    headers: Record<string, string> = {}
  ) {
    const response = await worker.fetch(
      new Request(new URL(path, BASE), {
        method: body ? "POST" : "GET",
        headers: {
          cookie: [...this.cookies].map(([name, value]) => `${name}=${value}`).join("; "),
          origin: BASE,
          "content-type": "application/json",
          ...headers
        },
        ...(body ? { body: JSON.stringify(body) } : {})
      }),
      appleEnv
    )
    for (const cookie of response.headers.getSetCookie()) {
      const first = cookie.split(";")[0]!
      const split = first.indexOf("=")
      this.cookies.set(first.slice(0, split), first.slice(split + 1))
    }
    return response
  }

  async start(scheme = "codevisor") {
    const response = await this.request(
      `/login/apple?redirect=${encodeURIComponent(`/auth/handoff?app=${scheme}`)}`
    )
    expect(response.status).toBe(302)
    const authorization = new URL(response.headers.get("location")!)
    expect(authorization.origin).toBe(issuer)
    expect(authorization.searchParams.get("client_id")).toBe(clientId)
    expect(authorization.searchParams.get("response_mode")).toBe("form_post")
    expect(response.headers.getSetCookie().join(";")).toContain("state")
    return authorization.searchParams.get("state")!
  }

  async finish(state: string, token: string, name?: string) {
    const code = `code-${state}`
    codes.set(code, token)
    // Safari omits SameSite=Lax cookies on Apple's cross-origin form POST.
    // Better Auth redirects to GET, where this browser sends its state cookie.
    const posted = await worker.fetch(
      new Request(`${BASE}/api/auth/callback/apple`, {
        method: "POST",
        headers: { origin: issuer, "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          code,
          state,
          ...(name ? { user: JSON.stringify({ name: { firstName: name } }) } : {})
        })
      }),
      appleEnv
    )
    expect(posted.status).toBe(302)
    return this.request(posted.headers.get("location")!)
  }

  async session() {
    return (await this.request("/api/auth/get-session")).json() as Promise<{
      user: { id: string; email: string; name: string }
    } | null>
  }

  async handoff() {
    const generated = await this.request("/auth/handoff?app=codevisor")
    expect(generated.status).toBe(302)
    expect(await generated.text()).toBe("")
    const callback = new URL(generated.headers.get("location")!)
    expect(callback.protocol).toBe("codevisor:")
    const token = callback.searchParams.get("ott")!
    const verified = await worker.fetch(
      new Request(`${BASE}/api/auth/one-time-token/verify`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ token })
      }),
      appleEnv
    )
    expect(verified.status).toBe(200)
    expect(verified.headers.get("set-auth-token")).toBeTruthy()
    return { ott: token, token: verified.headers.get("set-auth-token")! }
  }
}

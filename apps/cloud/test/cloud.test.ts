// @boundaries-ignore intentionally resolved to package source: this app bundles @codevisor/api from src (tsconfig paths / vite alias)
import { CLOUD_PROTOCOL_VERSION } from "@codevisor/api"
import { env, SELF } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { BASE, devLogin, authed, connectMachine } from "./cloud-test-support.js"

describe("discovery", () => {
  it("serves instance metadata", async () => {
    const response = await SELF.fetch(`${BASE}/.well-known/codevisor`)
    expect(response.status).toBe(200)
    const body = (await response.json()) as Record<string, unknown>
    expect(body.service).toBe("codevisor-cloud")
    expect(body.protocols).toEqual([CLOUD_PROTOCOL_VERSION])
    expect(body.authProviders).toContain("dev")
  })

  it("serves health and human pages", async () => {
    expect((await SELF.fetch(`${BASE}/health`)).status).toBe(200)
    for (const path of ["/", "/login", "/device"]) {
      const response = await SELF.fetch(`${BASE}${path}`)
      expect(response.status).toBe(200)
      expect(await response.text()).toContain("<html")
    }
  })
})

describe("auth", () => {
  it("dev login issues a bearer-usable session token", async () => {
    const token = await devLogin()
    const session = await SELF.fetch(`${BASE}/api/auth/get-session`, { headers: authed(token) })
    const body = (await session.json()) as { user?: { email?: string } } | null
    expect(body?.user?.email).toBe("dev@codevisor.local")
  })

  it("completes the RFC 8628 device flow end-to-end", async () => {
    const requested = await SELF.fetch(`${BASE}/api/auth/device/code`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ client_id: "codevisor-machine" })
    })
    expect(requested.status).toBe(200)
    const grant = (await requested.json()) as {
      device_code: string
      user_code: string
      verification_uri: string
    }
    expect(grant.verification_uri).toContain("/device")

    // Polling before approval → authorization_pending.
    const pending = await SELF.fetch(`${BASE}/api/auth/device/token`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
        device_code: grant.device_code,
        client_id: "codevisor-machine"
      })
    })
    expect(pending.status).toBe(400)
    expect(((await pending.json()) as { error: string }).error).toBe("authorization_pending")

    // User approves in the browser (session-authenticated): the verification
    // page first claims the code for this session, then approves it.
    const token = await devLogin()
    const claimed = await SELF.fetch(
      `${BASE}/api/auth/device?user_code=${encodeURIComponent(grant.user_code)}`,
      { headers: authed(token) }
    )
    expect(claimed.status).toBeLessThan(400)
    const approved = await SELF.fetch(`${BASE}/api/auth/device/approve`, {
      method: "POST",
      headers: { "content-type": "application/json", ...authed(token) },
      body: JSON.stringify({ userCode: grant.user_code })
    })
    expect(approved.status).toBe(200)

    // Machine polls again → session token.
    const granted = await SELF.fetch(`${BASE}/api/auth/device/token`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
        device_code: grant.device_code,
        client_id: "codevisor-machine"
      })
    })
    expect(granted.status).toBe(200)
    const { access_token } = (await granted.json()) as { access_token: string }
    const session = await SELF.fetch(`${BASE}/api/auth/get-session`, {
      headers: authed(access_token)
    })
    const body = (await session.json()) as { user?: { id?: string } } | null
    expect(body?.user?.id).toBeTruthy()
  })

  it("rejects unknown device-flow clients", async () => {
    const response = await SELF.fetch(`${BASE}/api/auth/device/code`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ client_id: "not-codevisor" })
    })
    expect(response.status).toBeGreaterThanOrEqual(400)
  })

  it("refuses unauthenticated connections and API calls", async () => {
    expect((await SELF.fetch(`${BASE}/api/machines`)).status).toBe(401)
    expect(
      (await SELF.fetch(`${BASE}/connect`, { headers: { Upgrade: "websocket" } })).status
    ).toBe(401)
    expect(
      (
        await SELF.fetch(`${BASE}/connect`, {
          headers: { Upgrade: "websocket", "x-api-key": "bogus" }
        })
      ).status
    ).toBe(401)
    expect((await SELF.fetch(`${BASE}/connect`)).status).toBe(426)
  })
})

describe("direct GitHub sign-in", () => {
  it("redirects straight to GitHub with state cookies when configured", async () => {
    const { default: worker } = await import("../src/index.js")
    const githubEnv = {
      ...env,
      GITHUB_CLIENT_ID: "Iv23test",
      GITHUB_CLIENT_SECRET: "secret"
    }
    const response = await worker.fetch(
      new Request(`${BASE}/login/github?redirect=%2Fauth%2Fhandoff%3Fapp%3Dcodevisor-dev`),
      githubEnv
    )
    expect(response.status).toBe(302)
    const location = response.headers.get("location") ?? ""
    expect(location).toContain("github.com/login/oauth/authorize")
    expect(location).toContain("client_id=Iv23test")
    // Better Auth's state/PKCE cookie must ride along into the browser.
    expect(response.headers.getSetCookie().join(";")).toContain("state")
  })

  it("falls back to the login page without GitHub, and rejects absolute redirects", async () => {
    const fallback = await SELF.fetch(`${BASE}/login/github`, { redirect: "manual" })
    expect(fallback.status).toBe(302)
    expect(fallback.headers.get("location")).toContain("/login?redirect=")

    const evil = await SELF.fetch(`${BASE}/login/github?redirect=https%3A%2F%2Fevil.example`, {
      redirect: "manual"
    })
    expect(evil.status).toBe(400)
    const schemeless = await SELF.fetch(`${BASE}/login/github?redirect=%2F%2Fevil.example`, {
      redirect: "manual"
    })
    expect(schemeless.status).toBe(400)
  })
})

describe("dev auth gating", () => {
  it("hides dev login when DEV_AUTH is not enabled", async () => {
    const { default: worker } = await import("../src/index.js")
    const { DEV_AUTH: _devAuth, ...prodEnv } = { ...env, BETTER_AUTH_SECRET: "x".repeat(40) }
    const response = await worker.fetch(
      new Request(`${BASE}/dev/login`, { method: "POST" }),
      prodEnv
    )
    expect(response.status).toBe(404)
    const discovery = await worker.fetch(new Request(`${BASE}/.well-known/codevisor`), prodEnv)
    const body = (await discovery.json()) as { authProviders: string[] }
    expect(body.authProviders).not.toContain("dev")
  })
})

describe("machine credential probe", () => {
  it("confirms valid keys and rejects missing or invalid ones", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "probe-vps")
    const valid = await SELF.fetch(`${BASE}/api/machine/credential`, {
      headers: { "x-api-key": machine.apiKey }
    })
    expect(valid.status).toBe(200)
    expect((await SELF.fetch(`${BASE}/api/machine/credential`)).status).toBe(401)
    const bogus = await SELF.fetch(`${BASE}/api/machine/credential`, {
      headers: { "x-api-key": "not-a-key" }
    })
    expect(bogus.status).toBe(401)
  })
})

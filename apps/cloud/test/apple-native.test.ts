import { env } from "cloudflare:test"
import { describe, expect, it, onTestFinished, vi } from "vitest"
import worker from "../src/index.js"
import {
  appleEnv,
  Browser,
  clientId,
  codes,
  identityToken,
  nativeClientId,
  revoked,
  subject
} from "./apple-auth-test-support.js"
import { authed, BASE, connectMachine, devLogin } from "./cloud-test-support.js"

const request = (path: string, body: Record<string, unknown>, token?: string) =>
  worker.fetch(
    new Request(`${BASE}/api/auth/${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", ...(token ? authed(token) : {}) },
      body: JSON.stringify(body)
    }),
    appleEnv
  )

const start = async (token?: string) => {
  const response = await request("apple/native/start", { link: Boolean(token) }, token)
  expect(response.status).toBe(200)
  return response.json() as Promise<{ id: string; nonce: string }>
}

const credentials = async (
  challenge: { id: string; nonce: string },
  claims = {},
  audience = nativeClientId
) => {
  const code = `native-${challenge.id}`
  codes.set(code, await identityToken({ nonce: challenge.nonce, ...claims }, audience))
  return { challengeId: challenge.id, authorizationCode: code, firstName: "Taylor" }
}

const complete = async (challenge: { id: string; nonce: string }, token?: string) => {
  const response = await request("apple/native/complete", await credentials(challenge), token)
  expect(response.status).toBe(200)
  return response.headers.get("set-auth-token")!
}

const session = async (token: string) => {
  const response = await worker.fetch(
    new Request(`${BASE}/api/auth/get-session`, { headers: authed(token) }),
    appleEnv
  )
  return response.json() as Promise<{ user: { id: string; name: string } } | null>
}

describe("native Apple authentication", () => {
  it("native iOS and browser macOS share one account and machine roster", async () => {
    const mac = new Browser()
    await mac.finish(await mac.start(), await identityToken(), "Taylor")
    const macSession = (await mac.session())!
    const macToken = await mac.handoff()
    const machine = await connectMachine(macToken.token, "Native Apple Mac", "native-apple-mac")
    onTestFinished(() => machine.socket.close())
    const challenge = await start()
    const response = await request(
      "apple/native/complete",
      await credentials(challenge, { email: undefined })
    )
    expect(response.status).toBe(200)
    const token = response.headers.get("set-auth-token")!
    expect((await session(token))?.user).toEqual(macSession.user)
    const machines = await worker.fetch(
      new Request(`${BASE}/api/machines`, { headers: authed(token) }),
      appleEnv
    )
    expect(await machines.json()).toMatchObject({ machines: [{ deviceId: machine.deviceId }] })
  })

  it("a native-first account is reused by browser sign-in", async () => {
    const token = await complete(await start())
    const phone = (await session(token))!
    const mac = new Browser()
    await mac.finish(await mac.start(), await identityToken({ email: undefined }))
    expect((await mac.session())?.user).toEqual(phone.user)
  })

  it.each(["nonce", "audience", "expired challenge", "invalid code"])(
    "rejects %s",
    async (failure) => {
      const challenge = await start()
      const body = await credentials(
        challenge,
        failure === "nonce" ? { nonce: "other-request" } : {},
        failure === "audience" ? clientId : nativeClientId
      )
      if (failure === "expired challenge") vi.advanceTimersByTime(10 * 60_000 + 1)
      if (failure === "invalid code") body.authorizationCode = "invalid"
      const response = await request("apple/native/complete", body)
      expect(response.status).toBe(401)
      expect(response.headers.get("set-auth-token")).toBeNull()
      expect(
        await env.DB.prepare(
          "SELECT id FROM account WHERE provider_id = 'apple' AND account_id = ?"
        )
          .bind(subject)
          .first()
      ).toBeNull()
    }
  )

  it("consumes a challenge only once even with concurrent completion", async () => {
    const challenge = await start()
    const body = await credentials(challenge)
    const results = await Promise.all([
      request("apple/native/complete", body),
      request("apple/native/complete", body)
    ])
    expect(results.map((response) => response.status).sort()).toEqual([200, 401])
    expect((await request("apple/native/complete", body)).status).toBe(401)
  })

  it("requires authentication to request account linking", async () => {
    expect((await request("apple/native/start", { link: true })).status).toBe(401)
  })

  it("explicitly links a different relay email without changing the signed-in account", async () => {
    const token = await devLogin()
    const existing = (await session(token))!
    const linkedToken = await complete(await start(token), token)
    expect(linkedToken).toBe(token)
    expect((await session(await complete(await start())))?.user.id).toBe(existing.user.id)
    const accounts = await worker.fetch(
      new Request(`${BASE}/api/auth/list-accounts`, { headers: authed(token) }),
      appleEnv
    )
    expect(await accounts.json()).toEqual(
      expect.arrayContaining([expect.objectContaining({ providerId: "apple" })])
    )
  })

  it("binds linking to the original session, including a different session for the same user", async () => {
    const token = await devLogin()
    const challenge = await start(token)
    const otherSession = await devLogin()
    expect(otherSession).not.toBe(token)
    expect(
      (await request("apple/native/complete", await credentials(challenge), otherSession)).status
    ).toBe(401)
    expect(
      (await request("apple/native/complete", await credentials(await start(token)))).status
    ).toBe(401)
  })

  it("never implicitly links by matching email", async () => {
    await devLogin()
    const body = await credentials(await start(), { email: "dev@codevisor.local" })
    expect((await request("apple/native/complete", body)).status).toBe(401)
  })

  it("never moves an Apple identity from another account", async () => {
    const owner = (await session(await complete(await start())))!
    const token = await devLogin()
    const response = await request(
      "apple/native/complete",
      await credentials(await start(token)),
      token
    )
    expect(response.status).toBe(409)
    expect((await session(await complete(await start())))?.user.id).toBe(owner.user.id)
  })

  it("revokes native refresh tokens with the App ID when deleting the account", async () => {
    const token = await complete(await start())
    expect((await request("delete-user", {}, token)).status).toBe(200)
    expect(revoked).toEqual(["apple-refresh"])
    expect(await session(token)).toBeNull()
  })

  it("does not enable native authorization without configured credentials", async () => {
    const response = await worker.fetch(
      new Request(`${BASE}/api/auth/apple/native/start`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}"
      }),
      { ...appleEnv, APPLE_NATIVE_CLIENT_ID: undefined }
    )
    expect(response.status).toBe(404)
  })
})

describe("headless native handoffs", () => {
  it("keeps the provider picker in the app and returns failures to it", async () => {
    const browser = new Browser()
    const bridge = await browser.request("/auth/connect/apple?app=codevisor-dev")
    const html = await bridge.text()
    expect(html).not.toMatch(/<(button|h1|form|p)[\s>]/)
    expect(html).toContain('provider: "apple"')
    expect(html).toContain("one-time-token/verify")
    expect(bridge.headers.get("cache-control")).toBe("no-store")
    const error = await browser.request("/auth/handoff?app=codevisor-dev&error=link_failed")
    expect(error.headers.get("location")).toBe("codevisor-dev://cloud-auth?error=sign_in_failed")
    expect(await error.text()).toBe("")
    expect((await browser.request("/auth/handoff?app=attacker")).status).toBe(400)
    expect((await browser.request("/auth/connect/apple?app=codevisor%22%3Cscript%3E")).status).toBe(
      400
    )
    const signedOut = await browser.request("/auth/handoff?app=codevisor")
    expect(signedOut.headers.get("location")).toBe("codevisor://cloud-auth?error=session_expired")
  })
})

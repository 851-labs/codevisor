import { env } from "cloudflare:test"
import { generateKeyPair, jwtVerify, SignJWT } from "jose"
import { describe, expect, it, onTestFinished, vi } from "vitest"
import { appleClientSecret } from "../src/apple-auth.js"
import worker from "../src/index.js"
import { CLOSE_REVOKED } from "../src/user-hub.js"
import { authed, BASE, connectMachine, devLogin } from "./cloud-test-support.js"
import {
  appleEnv,
  Browser,
  clientId,
  clientPublicKey,
  identityToken,
  issuer,
  revoked,
  setRevokeFails,
  signingKey,
  subject
} from "./apple-auth-test-support.js"

describe("Apple Cloud authorization", () => {
  it("advertises Apple only when all four credentials exist", async () => {
    for (const configured of [appleEnv, { ...appleEnv, APPLE_PRIVATE_KEY: "" }]) {
      const response = await worker.fetch(new Request(`${BASE}/.well-known/codevisor`), configured)
      const data = (await response.json()) as { authProviders: string[] }
      expect(data.authProviders.includes("apple")).toBe(Boolean(configured.APPLE_PRIVATE_KEY))
    }
  })

  it("rotates client assertions without a deployment", async () => {
    const first = await appleClientSecret(appleEnv)
    const { payload } = await jwtVerify(first, clientPublicKey, { audience: issuer })
    expect(payload.exp! - payload.iat!).toBe(300)
    vi.advanceTimersByTime(301_000)
    const second = await appleClientSecret(appleEnv)
    expect(second).not.toBe(first)
    await expect(jwtVerify(second, clientPublicKey, { audience: issuer })).resolves.toBeDefined()
    await expect(jwtVerify(first, clientPublicKey)).rejects.toThrow()
  })

  it("requires recent sign-in before revoking Apple or deleting data", async () => {
    const browser = new Browser()
    await browser.finish(await browser.start(), await identityToken())
    vi.advanceTimersByTime(25 * 60 * 60 * 1000)
    const response = await browser.request("/api/auth/delete-user", {})
    expect(response.status).toBe(400)
    expect(await response.json()).toMatchObject({ code: "SESSION_EXPIRED" })
    expect(revoked).toEqual([])
    expect(await browser.session()).not.toBeNull()
  })

  it("enforces provider identity uniqueness in the database", async () => {
    const browser = new Browser()
    await browser.finish(await browser.start(), await identityToken())
    const userId = (await browser.session())!.user.id
    await expect(
      env.DB.prepare(
        "INSERT INTO account (id, account_id, provider_id, user_id, updated_at) VALUES (?, ?, 'apple', ?, ?)"
      )
        .bind("duplicate-apple", subject, userId, Date.now())
        .run()
    ).rejects.toThrow("UNIQUE constraint failed")
  })

  it("Mac and iPhone handoffs reach one Cloud user and the same machines, retaining the first name", async () => {
    const mac = new Browser()
    const macDone = await mac.finish(
      await mac.start("codevisor-dev"),
      await identityToken(),
      "Taylor"
    )
    expect(macDone.headers.get("location")).toBe("/auth/handoff?app=codevisor-dev")
    const macSession = (await mac.session())!
    expect(macSession.user.name).toBe("Taylor")
    const macToken = await mac.handoff()
    const machine = await connectMachine(macToken.token, "apple-mac", "mac-device")
    onTestFinished(() => machine.socket.close())
    const phone = new Browser()
    // Apple can omit email/name on later authorizations; use the stored subject.
    const phoneDone = await phone.finish(
      await phone.start(),
      await identityToken({ email: undefined })
    )
    expect(phoneDone.headers.get("location")).toBe("/auth/handoff?app=codevisor")
    expect((await phone.session())?.user).toEqual(macSession.user)
    const phoneToken = await phone.handoff()
    const machines = await worker.fetch(
      new Request(`${BASE}/api/machines`, { headers: authed(phoneToken.token) }),
      appleEnv
    )
    expect(await machines.json()).toMatchObject({ machines: [{ deviceId: machine.deviceId }] })
    expect(
      (
        await env.DB.prepare(
          "SELECT count(*) AS count FROM account WHERE provider_id = 'apple' AND account_id = ?"
        )
          .bind(subject)
          .first<{ count: number }>()
      )?.count
    ).toBe(1)
    const replay = await worker.fetch(
      new Request(`${BASE}/api/auth/one-time-token/verify`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ token: phoneToken.ott })
      }),
      appleEnv
    )
    expect(replay.status).toBe(400)
    machine.socket.close()
  })

  it("rejects a callback in a different browser and direct ID-token replay", async () => {
    const state = await new Browser().start()
    const other = new Browser()
    const response = await other.finish(state, await identityToken())
    expect(response.headers.get("location")).toContain("error=")
    expect(await other.session()).toBeNull()
    const direct = await other.request("/api/auth/sign-in/social", {
      provider: "apple",
      idToken: { token: await identityToken() }
    })
    expect(direct.status).toBeGreaterThanOrEqual(400)
    expect(await other.session()).toBeNull()
  })

  it.each(["audience", "issuer", "expiry", "signature"])("rejects invalid %s", async (failure) => {
    const browser = new Browser()
    const state = await browser.start()
    const jwt = new SignJWT({ email: "someone@example.com" })
      .setProtectedHeader({ alg: "RS256", kid: "test-apple-key" })
      .setSubject(subject)
      .setIssuer(failure === "issuer" ? "https://attacker.example" : issuer)
      .setAudience(failure === "audience" ? "another-app" : clientId)
      .setIssuedAt()
      .setExpirationTime(failure === "expiry" ? "-1m" : "5m")
    const key = failure === "signature" ? (await generateKeyPair("RS256")).privateKey : signingKey
    const response = await browser.finish(state, await jwt.sign(key))
    expect(response.status).toBe(302)
    expect(response.headers.get("location")).toContain("error=")
    expect(await browser.session()).toBeNull()
  })

  it("links a relay email to an existing GitHub account only after explicit authenticated linking", async () => {
    const token = await devLogin()
    const current = await worker.fetch(
      new Request(`${BASE}/api/auth/get-session`, { headers: authed(token) }),
      appleEnv
    )
    const { user } = (await current.json()) as { user: { id: string } }
    await env.DB.prepare(
      "INSERT INTO account (id, account_id, provider_id, user_id, updated_at) VALUES (?, ?, 'github', ?, ?)"
    )
      .bind("github-account", "github-person", user.id, Date.now())
      .run()
    const browser = new Browser()
    const link = await browser.request(
      "/api/auth/link-social",
      {
        provider: "apple",
        callbackURL: "/account",
        errorCallbackURL: "/account?failed=1"
      },
      authed(token)
    )
    expect(link.status).toBe(200)
    const { url } = (await link.json()) as { url: string }
    const completed = await browser.finish(
      new URL(url).searchParams.get("state")!,
      await identityToken()
    )
    expect(completed.headers.get("location")).toBe("/account")
    const phone = new Browser()
    await phone.finish(await phone.start(), await identityToken())
    expect((await phone.session())?.user.id).toBe(user.id)
    expect(
      (
        await env.DB.prepare(
          "SELECT count(*) AS count FROM account WHERE provider_id = 'apple' AND account_id = ?"
        )
          .bind(subject)
          .first<{ count: number }>()
      )?.count
    ).toBe(1)
  })

  it("does not implicitly link matching emails or move an Apple identity between accounts", async () => {
    const token = await devLogin()
    const unlinked = new Browser()
    const denied = await unlinked.finish(
      await unlinked.start(),
      await identityToken({ email: "dev@codevisor.local" })
    )
    expect(denied.headers.get("location")).toContain("account_not_linked")
    expect(await unlinked.session()).toBeNull()
    const owner = new Browser()
    await owner.finish(await owner.start(), await identityToken())
    const originalId = (await owner.session())!.user.id
    const link = await owner.request(
      "/api/auth/link-social",
      {
        provider: "apple",
        callbackURL: "/account",
        errorCallbackURL: "/account?failed=1"
      },
      authed(token)
    )
    const { url } = (await link.json()) as { url: string }
    const deniedLink = await owner.finish(
      new URL(url).searchParams.get("state")!,
      await identityToken()
    )
    expect(deniedLink.headers.get("location")).toContain("account_already_linked_to_different_user")
    const account = await env.DB.prepare(
      "SELECT user_id FROM account WHERE provider_id = 'apple' AND account_id = ?"
    )
      .bind(subject)
      .first<{ user_id: string }>()
    expect(account?.user_id).toBe(originalId)
  })

  it("revokes Apple, closes the hub, and deletes sessions and machine credentials on deletion", async () => {
    const browser = new Browser()
    await browser.finish(await browser.start(), await identityToken())
    const user = (await browser.session())!.user
    const { token } = await browser.handoff()
    const machine = await connectMachine(token, "deleted-mac", "deleted-device")
    onTestFinished(() => machine.socket.close())
    setRevokeFails(true)
    expect((await browser.request("/api/auth/delete-user", {})).status).toBe(500)
    expect(await browser.session()).not.toBeNull()
    setRevokeFails(false)
    const close = new Promise<CloseEvent>((resolve) =>
      machine.socket.addEventListener("close", resolve, { once: true })
    )
    expect((await browser.request("/api/auth/delete-user", {})).status).toBe(200)
    expect((await close).code).toBe(CLOSE_REVOKED)
    expect(revoked).toEqual(["apple-refresh"])
    expect(await browser.session()).toBeNull()
    for (const [table, column] of [
      ["user", "id"],
      ["session", "user_id"],
      ["account", "user_id"],
      ["apikey", "reference_id"]
    ]) {
      expect(
        (
          await env.DB.prepare(`SELECT count(*) AS count FROM ${table} WHERE ${column} = ?`)
            .bind(user.id)
            .first<{ count: number }>()
        )?.count
      ).toBe(0)
    }
    const hub = env.USER_HUB.get(env.USER_HUB.idFromName(user.id))
    expect(await hub.listMachines()).toEqual([])
    expect((await hub.fetch(`${BASE}/connect`, { headers: { Upgrade: "websocket" } })).status).toBe(
      401
    )
  })
})

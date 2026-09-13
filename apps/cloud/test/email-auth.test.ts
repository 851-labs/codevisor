import { env } from "cloudflare:test"
import { beforeEach, describe, expect, it, vi } from "vitest"
import worker from "../src/index.js"
import type { CloudEnv } from "../src/env.js"
import { sendAuthEmail } from "../src/email-auth.js"
import { authed, BASE } from "./cloud-test-support.js"

let email: string
let clientIP: string
let fixtureNumber = 0
const password = "a-correct-test-password"
type Mail = { from: string; to: string[]; subject: string; text: string; html: string }
let messages: Mail[]
let configured: CloudEnv

beforeEach(({ task }) => {
  email = `${task.name.replace(/[^a-z]/gi, "-")}@example.com`
  clientIP = `192.0.2.${++fixtureNumber}`
  messages = []
  configured = {
    ...env,
    DEV_AUTH: "0",
    BETTER_AUTH_SECRET: "email-auth-test-secret-at-least-32-characters",
    RESEND_API_KEY: "test-resend-key",
    AUTH_EMAIL_FETCH: async (url, init) => {
      expect(url).toBe("https://api.resend.com/emails")
      expect(init?.headers).toMatchObject({ Authorization: "Bearer test-resend-key" })
      messages.push(JSON.parse(init!.body as string) as Mail)
      return Response.json({ id: "test-mail" })
    }
  }
})

const request = (path: string, body: object) =>
  worker.fetch(
    new Request(`${BASE}/api/auth/${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", "cf-connecting-ip": clientIP },
      body: JSON.stringify(body)
    }),
    configured
  )
const signup = () => request("sign-up/email", { email, password, name: "Email User" })
const login = (value = password) => request("sign-in/email", { email, password: value })
const code = () => messages.at(-1)!.text.match(/\n\n(\d{6})\n\n/)![1]!
const verify = (otp = code()) => request("email-otp/verify-email", { email, otp })
const resend = () =>
  request("email-otp/send-verification-otp", { email, type: "email-verification" })
const reset = (otp = code()) =>
  request("email-otp/reset-password", { email, otp, password: "a-new-test-password" })
const session = (token: string) =>
  worker.fetch(new Request(`${BASE}/api/auth/get-session`, { headers: authed(token) }), configured)

describe("native email authentication", () => {
  it("advertises email only with a configured mail service", async () => {
    for (const key of ["test-key", ""]) {
      const response = await worker.fetch(new Request(`${BASE}/.well-known/codevisor`), {
        ...configured,
        RESEND_API_KEY: key
      })
      expect(
        ((await response.json()) as { authProviders: string[] }).authProviders.includes("email")
      ).toBe(Boolean(key))
    }
  })

  it("requires signup verification, then signs in with a password without more email", async () => {
    const created = await signup()
    expect(created.status).toBe(200)
    expect(await created.json()).toMatchObject({ token: null, user: { emailVerified: false } })
    expect(created.headers.get("set-auth-token")).toBeNull()
    expect(messages).toHaveLength(1)
    expect(messages[0]).toMatchObject({
      from: "Codevisor <noreply@auth.codevisor.dev>",
      to: [email]
    })
    expect(await (await login()).json()).toMatchObject({ code: "EMAIL_NOT_VERIFIED" })
    expect(messages).toHaveLength(1)
    const confirmed = await verify()
    expect(confirmed.status).toBe(200)
    const token = confirmed.headers.get("set-auth-token")!
    expect(token).toBeTruthy()
    expect(await (await session(token)).json()).toMatchObject({ user: { emailVerified: true } })
    expect((await login()).status).toBe(200)
    expect(messages).toHaveLength(1)
  })

  it("stores hashed codes and passwords and consumes verification codes once", async () => {
    await signup()
    const otp = code()
    const values = await env.DB.prepare("SELECT value FROM verification WHERE identifier = ?")
      .bind(`email-verification-otp-${email}`)
      .all<{ value: string }>()
    expect(values.results.some((row) => row.value.startsWith(`${otp}:`))).toBe(false)
    const account = await env.DB.prepare(
      "SELECT password FROM account WHERE user_id IN (SELECT id FROM user WHERE email = ?) AND provider_id = 'credential'"
    )
      .bind(email)
      .first<{ password: string }>()
    expect(account?.password).toBeTruthy()
    expect(account?.password).not.toBe(password)
    expect((await verify(otp)).status).toBe(200)
    expect((await verify(otp)).status).toBe(400)
  })

  it("invalidates the previous code when resending", async () => {
    await signup()
    // Fix the old stored code so the assertion cannot depend on random collisions.
    await env.DB.prepare(
      "UPDATE verification SET value = 'invalid-old-code:0' WHERE identifier = ?"
    )
      .bind(`email-verification-otp-${email}`)
      .run()
    expect((await resend()).status).toBe(200)
    expect(messages).toHaveLength(2)
    expect((await verify()).status).toBe(200)
  })

  it("expires codes after ten minutes", async () => {
    await signup()
    vi.advanceTimersByTime(600_001)
    expect(await (await verify()).json()).toMatchObject({ code: "OTP_EXPIRED" })
  })

  it("limits incorrect attempts and requires a new code", async () => {
    await signup()
    const otp = code()
    for (let attempt = 0; attempt < 5; attempt++) {
      vi.advanceTimersByTime(61_000)
      expect((await verify("not-a-code")).status).toBe(400)
    }
    vi.advanceTimersByTime(61_000)
    expect(await (await verify(otp)).json()).toMatchObject({ code: "TOO_MANY_ATTEMPTS" })
    await resend()
    expect((await verify()).status).toBe(200)
  })

  it("resets through a code, revokes sessions, and rejects code replay and the old password", async () => {
    await signup()
    const token = (await verify()).headers.get("set-auth-token")!
    expect((await request("email-otp/request-password-reset", { email })).status).toBe(200)
    expect(messages.at(-1)?.subject).toBe("Reset your password — Codevisor")
    const otp = code()
    expect((await reset(otp)).status).toBe(200)
    expect(await (await session(token)).json()).toBeNull()
    expect((await login()).status).toBe(401)
    expect((await login("a-new-test-password")).status).toBe(200)
    expect((await reset(otp)).status).toBe(400)
  })

  it("keeps signup and password reset codes separate", async () => {
    await signup()
    expect((await reset(code())).status).toBe(400)
    expect((await verify()).status).toBe(200)
  })

  it("does not reveal unknown addresses in reset responses", async () => {
    await signup()
    const known = await request("email-otp/request-password-reset", { email })
    const unknown = await request("email-otp/request-password-reset", {
      email: "unknown@example.com"
    })
    expect(unknown.status).toBe(known.status)
    expect(await unknown.json()).toEqual(await known.json())
    expect(messages).toHaveLength(2)
  })

  it("does not enable passwordless sign-in", async () => {
    await signup()
    expect((await request("sign-in/email-otp", { email, otp: code() })).status).toBe(404)
    expect(
      (await request("email-otp/send-verification-otp", { email, type: "sign-in" })).status
    ).toBe(400)
    expect(messages).toHaveLength(1)
  })

  it("rate limits code sending", async () => {
    await signup()
    for (let attempt = 0; attempt < 3; attempt++) await resend()
    expect((await resend()).status).toBe(429)
  })

  it("returns a safe error when delivery fails and lets signup resume with resend", async () => {
    const send = configured.AUTH_EMAIL_FETCH!
    configured.AUTH_EMAIL_FETCH = async () =>
      new Response("sensitive provider response", { status: 503 })
    const response = await signup()
    expect(response.status).toBe(503)
    expect(await response.json()).toMatchObject({ code: "EMAIL_DELIVERY_FAILED" })
    configured.AUTH_EMAIL_FETCH = send
    expect((await resend()).status).toBe(200)
    expect((await verify()).status).toBe(200)
  })

  it("sanitizes transport failures", async () => {
    configured.AUTH_EMAIL_FETCH = async () => {
      throw new Error("secret")
    }
    await expect(sendAuthEmail(configured, email, "123456", false)).rejects.toMatchObject({
      body: { code: "EMAIL_DELIVERY_FAILED", message: "Couldn't send your code. Please try again." }
    })
  })
})

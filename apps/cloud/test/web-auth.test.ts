import { env } from "cloudflare:test"
import { describe, expect, it } from "vitest"

import type { CloudEnv } from "../src/env.js"
import worker from "../src/index.js"
import { loginURL, validAuthRedirect } from "../src/pages/auth-navigation.js"
import { BASE } from "./cloud-test-support.js"

const baseEnv: CloudEnv = {
  ...env,
  DEV_AUTH: "0",
  BETTER_AUTH_SECRET: "web-auth-test-secret-at-least-32-characters",
  GITHUB_CLIENT_ID: "",
  GITHUB_CLIENT_SECRET: "",
  APPLE_CLIENT_ID: "",
  APPLE_PRIVATE_KEY: "",
  RESEND_API_KEY: ""
}

const cookies = (response: Response) =>
  response.headers
    .getSetCookie()
    .map((cookie) => cookie.split(";")[0])
    .join("; ")

describe("web auth navigation", () => {
  it.each([
    "https://evil.example",
    "//evil.example",
    "/\\evil.example",
    "/\tevil.example",
    "/\nevil.example",
    "javascript:alert(1)",
    "/\u007fevil.example",
    ""
  ])("rejects unsafe destinations on every login entry: %j", async (redirect) => {
    expect(validAuthRedirect(redirect)).toBe(false)
    await Promise.all(
      ["/login", "/login/github", "/dev-login"].map(async (path) => {
        const response = await worker.fetch(
          new Request(`${BASE}${path}?${new URLSearchParams({ redirect })}`),
          { ...baseEnv, DEV_AUTH: "1" }
        )
        expect(response.status).toBe(400)
      })
    )
  })

  it.each(["/device?user_code=ABCD-EFGH", "/auth/handoff?app=codevisor-dev"])(
    "preserves %s across auth entry screens",
    async (redirect) => {
      expect(validAuthRedirect(redirect)).toBe(true)
      const url = new URL(loginURL(redirect, "forgot-password"), BASE)
      expect(url.searchParams.get("redirect")).toBe(redirect)
      expect(url.searchParams.get("step")).toBe("forgot-password")
      const response = await worker.fetch(new Request(url), {
        ...baseEnv,
        RESEND_API_KEY: "test-key"
      })
      const body = await response.text()
      expect(response.status).toBe(200)
      expect(response.headers.get("cache-control")).toBe("no-store")
      expect(body).toContain(`data-redirect="${redirect}"`)
      if (redirect.startsWith("/device"))
        expect(body).toContain("Sign in to connect this machine to your account.")
    }
  )

  it("escapes return destinations embedded in the page", async () => {
    const redirect = '/?value="/><script>alert(1)</script>'
    const response = await worker.fetch(new Request(`${BASE}${loginURL(redirect)}`), baseEnv)
    const body = await response.text()
    expect(body).not.toContain(redirect)
    expect(body).toContain("&lt;script&gt;")
  })
})

describe("web sign-in methods", () => {
  it.each([false, true])("offers email only when mail is configured (%j)", async (enabled) => {
    const response = await worker.fetch(new Request(`${BASE}/login`), {
      ...baseEnv,
      RESEND_API_KEY: enabled ? "test-key" : ""
    })
    const body = await response.text()
    expect(body.includes('id="email-auth"')).toBe(enabled)
    expect(body.includes("No sign-in methods are configured")).toBe(!enabled)
    expect(body).not.toContain('id="dev-login"')
  })

  it("renders both provider options with matching controls and preserves their destination", async () => {
    const redirect = "/device?user_code=ABCD-EFGH"
    const response = await worker.fetch(new Request(`${BASE}${loginURL(redirect)}`), {
      ...baseEnv,
      GITHUB_CLIENT_ID: "test-github",
      GITHUB_CLIENT_SECRET: "test-secret",
      APPLE_CLIENT_ID: "test-apple",
      APPLE_TEAM_ID: "test-team",
      APPLE_KEY_ID: "test-key",
      APPLE_PRIVATE_KEY: "test-private-key"
    })
    const body = await response.text()
    for (const provider of ["apple", "github"]) {
      expect(body).toContain(`id="${provider}" class="auth-provider"`)
      expect(body).toContain(`/login/${provider}?redirect=${encodeURIComponent(redirect)}`)
    }
    expect(body).not.toContain("appleid.cdn-apple.com")
    expect(body).not.toContain("Authenticate to continue")
  })
})

describe("browser email sessions", () => {
  it("verifies signup with a cookie, resumes machine approval, and signs in after a password reset", async () => {
    const email = "web-auth-browser@example.com"
    const password = "a-web-test-password"
    let mail = ""
    const configured: CloudEnv = {
      ...baseEnv,
      RESEND_API_KEY: "test-key",
      AUTH_EMAIL_FETCH: async (_input, init) => {
        mail = (JSON.parse(init!.body as string) as { text: string }).text
        return Response.json({ id: "web-test-mail" })
      }
    }
    const request = (path: string, body: object) =>
      worker.fetch(
        new Request(`${BASE}/api/auth/${path}`, {
          method: "POST",
          headers: {
            "content-type": "application/json",
            origin: BASE,
            "cf-connecting-ip": "192.0.2.240"
          },
          body: JSON.stringify(body)
        }),
        configured
      )
    const otp = () => mail.match(/\n\n(\d{6})\n\n/)![1]!
    const session = (cookie: string) =>
      worker.fetch(new Request(`${BASE}/api/auth/get-session`, { headers: { cookie } }), configured)

    expect((await request("sign-up/email", { email, password, name: "Web User" })).status).toBe(200)
    expect(await (await request("sign-in/email", { email, password })).json()).toMatchObject({
      code: "EMAIL_NOT_VERIFIED"
    })
    const verified = await request("email-otp/verify-email", { email, otp: otp() })
    expect(verified.status).toBe(200)
    const cookie = cookies(verified)
    expect(cookie).toContain("session_token=")
    expect(await (await session(cookie)).json()).toMatchObject({
      user: { email, emailVerified: true }
    })

    const grant = await request("device/code", { client_id: "codevisor-machine" })
    const { user_code: userCode } = (await grant.json()) as { user_code: string }
    expect(grant.status).toBe(200)
    const claimed = await worker.fetch(
      new Request(`${BASE}/api/auth/device?user_code=${encodeURIComponent(userCode)}`, {
        headers: { cookie }
      }),
      configured
    )
    expect(claimed.status).toBeLessThan(400)
    const approved = await worker.fetch(
      new Request(`${BASE}/api/auth/device/approve`, {
        method: "POST",
        headers: { cookie, origin: BASE, "content-type": "application/json" },
        body: JSON.stringify({ userCode })
      }),
      configured
    )
    expect(approved.status).toBe(200)

    expect((await request("email-otp/request-password-reset", { email })).status).toBe(200)
    expect(
      (
        await request("email-otp/reset-password", {
          email,
          otp: otp(),
          password: "a-new-web-password"
        })
      ).status
    ).toBe(200)
    expect(await (await session(cookie)).json()).toBeNull()
    const signedIn = await request("sign-in/email", { email, password: "a-new-web-password" })
    expect(signedIn.status).toBe(200)
    expect(await (await session(cookies(signedIn))).json()).toMatchObject({ user: { email } })
  })
})

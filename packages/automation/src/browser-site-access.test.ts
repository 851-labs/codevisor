import { describe, expect, it } from "vitest"

import type { PageHandle } from "./browser-cdp-engine.js"
import { fakeBrowserRuntime, fakeCdpConnection } from "./browser-runtime-test-support.js"
import {
  grantSiteAccess,
  navigationFailure,
  observeSiteAccessEvent
} from "./browser-site-access.js"

const page: PageHandle = {
  target: { targetId: "tab", type: "page", title: "", url: "about:blank" },
  sessionId: "session"
}

const fixture = (failing: ReadonlyArray<string> = []) => {
  const sent: Array<readonly [string, unknown, string | undefined]> = []
  const failures = [...failing]
  const runtime = fakeBrowserRuntime({
    connection: fakeCdpConnection({
      send: async (method, params, sessionId) => {
        sent.push([method, params, sessionId])
        if (failures[0] === method) {
          failures.shift()
          throw new Error("Not attached to an active page")
        }
        if (method === "Runtime.evaluate") return { result: { value: "complete" } }
        return {}
      }
    }).connection
  })
  const event = (method: string, params: Record<string, unknown>, sessionId = page.sessionId) => {
    sent.length = 0
    observeSiteAccessEvent(runtime, method, params, sessionId)
    return sent[0]
  }
  return { runtime, sent, event }
}

const credentials = { username: "user", password: "secret" }
const challenge = (origin: string, requestId = "request", source = "Server") => ({
  requestId,
  authChallenge: { origin, source }
})

const declined = (requestId: string) => ({
  requestId,
  authChallengeResponse: { response: "Default" }
})
const certificateError = (requestURL: string, eventId = 7) => ({
  eventId,
  errorType: "ERR_CERT_AUTHORITY_INVALID",
  requestURL
})

describe("HTTP authentication", () => {
  it("answers challenges from the granted origin, once, and leaves every other one alone", async () => {
    const { runtime, sent, event } = fixture()
    await grantSiteAccess(runtime, page, "https://staging.test/admin?x=1", {
      httpCredentials: credentials
    })
    expect(sent).toEqual([
      [
        "Fetch.enable",
        { handleAuthRequests: true, patterns: [{ urlPattern: "https://staging.test/*" }] },
        "session"
      ]
    ])

    expect(event("Fetch.requestPaused", { requestId: "request" })).toEqual([
      "Fetch.continueRequest",
      { requestId: "request" },
      "session"
    ])
    const provided = {
      requestId: "request",
      authChallengeResponse: { response: "ProvideCredentials", ...credentials }
    }
    expect(event("Fetch.authRequired", challenge("https://staging.test"))).toEqual([
      "Fetch.continueWithAuth",
      provided,
      "session"
    ])
    expect(event("Fetch.authRequired", challenge("https://staging.test"))?.[1]).toEqual(
      declined("request")
    )
    expect(event("Fetch.authRequired", challenge("https://other.test", "other"))?.[1]).toEqual(
      declined("other")
    )
    expect(
      event("Fetch.authRequired", challenge("https://staging.test", "proxy", "Proxy"))?.[1]
    ).toEqual(declined("proxy"))
  })

  it("ignores tabs that were granted nothing, and forgets a tab when it detaches", async () => {
    const { runtime, event } = fixture()
    await grantSiteAccess(runtime, page, "https://staging.test/", { httpCredentials: credentials })

    expect(event("Fetch.requestPaused", { requestId: "request" }, "other-session")).toBeUndefined()
    event("Target.detachedFromTarget", { sessionId: "session" }, "browser")
    expect(event("Fetch.authRequired", challenge("https://staging.test"))).toBeUndefined()
  })

  it("rejects credentials it can't use and sends nothing", async () => {
    const { runtime, sent } = fixture()
    await expect(
      grantSiteAccess(runtime, page, "https://staging.test/", {
        httpCredentials: { username: "user" }
      })
    ).rejects.toThrow("httpCredentials must be { username, password }")
    await expect(
      grantSiteAccess(runtime, page, "not a url", { httpCredentials: credentials })
    ).rejects.toThrow("need a full URL")
    await grantSiteAccess(runtime, page, "https://staging.test/", {})
    expect(sent).toEqual([])
  })
})

describe("Untrusted certificates", () => {
  it("proceeds for the trusted host only, and explains the ones it refused", async () => {
    const { runtime, sent, event } = fixture()
    await grantSiteAccess(runtime, page, "https://staging.test:8443/", {
      ignoreCertificateErrors: true
    })
    expect(sent.map(([method, params]) => [method, params])).toEqual([
      ["Security.enable", {}],
      ["Security.setOverrideCertificateErrors", { override: true }]
    ])

    expect(
      event("Security.certificateError", certificateError("https://staging.test:8443/a"))
    ).toEqual(["Security.handleCertificateError", { eventId: 7, action: "continue" }, "session"])
    expect(
      event("Security.certificateError", certificateError("https://evil.test/", 8))?.[1]
    ).toEqual({ eventId: 8, action: "cancel" })
    expect(
      event("Security.certificateError", certificateError("https://staging.test/", 9))?.[1]
    ).toEqual({ eventId: 9, action: "cancel" })

    expect(
      navigationFailure(runtime, page, "https://evil.test/", "net::ERR_ABORTED").message
    ).toContain("The site's certificate isn't trusted (net::ERR_CERT_AUTHORITY_INVALID)")
    expect(navigationFailure(runtime, page, "https://fine.test/", "net::ERR_ABORTED").message).toBe(
      "net::ERR_ABORTED"
    )
  })

  it("leaves an error page first when the browser can't change certificate handling there", async () => {
    const { runtime, sent } = fixture(["Security.enable"])
    await grantSiteAccess(runtime, page, "https://staging.test/", {
      ignoreCertificateErrors: true
    })
    expect(sent.map(([method, params]) => [method, params])).toEqual([
      ["Security.enable", {}],
      ["Page.navigate", { url: "about:blank" }],
      ["Runtime.evaluate", expect.anything()],
      ["Security.enable", {}],
      ["Security.setOverrideCertificateErrors", { override: true }]
    ])
  })

  it("tells the agent how to get past a refused login or certificate", () => {
    const { runtime } = fixture()
    expect(
      navigationFailure(runtime, page, "https://a.test/", "net::ERR_INVALID_AUTH_CREDENTIALS")
        .message
    ).toContain("tab.goto(url, { httpCredentials: { username, password } })")
    expect(
      navigationFailure(runtime, page, "https://a.test/", "net::ERR_CERT_DATE_INVALID").message
    ).toContain("tab.goto(url, { ignoreCertificateErrors: true })")
    expect(navigationFailure(runtime, page, "https://a.test/", "net::ERR_FAILED").message).toBe(
      "net::ERR_FAILED"
    )
  })
})

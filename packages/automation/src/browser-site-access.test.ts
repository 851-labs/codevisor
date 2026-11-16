import { describe, expect, it } from "vitest"

import type { PageHandle } from "./browser-cdp-engine.js"
import { fakeBrowserRuntime, fakeCdpConnection } from "./browser-runtime-test-support.js"
import { beginSiteVisit, observeSiteAccessEvent } from "./browser-site-access.js"

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
  const visit = (url: string, args: Record<string, unknown> = {}) =>
    beginSiteVisit(runtime, page, url, args)
  const commands = () => sent.map(([method, params]) => [method, params])
  return { runtime, sent, event, visit, commands }
}

const credentials = { username: "user", password: "secret" }
const challenge = (origin: string, requestId = "request", source = "Server") => ({
  requestId,
  authChallenge: { origin, source }
})
const answer = (requestId: string, response: Record<string, unknown>) => ({
  requestId,
  authChallengeResponse: response
})
const documentsOf = (...origins: string[]) => ({
  handleAuthRequests: true,
  patterns: origins.map((origin) => ({ urlPattern: `${origin}/*`, resourceType: "Document" }))
})
const certificateError = (requestURL: string, eventId = 7) => ({
  eventId,
  errorType: "ERR_CERT_AUTHORITY_INVALID",
  requestURL
})
const signInNeeded = "This page asks for a username and password (HTTP authentication)"

describe("HTTP authentication", () => {
  it("refuses a sign-in challenge during a visit without credentials, then stops watching", async () => {
    const { commands, event, visit } = fixture()
    const visiting = await visit("https://staging.test/admin?x=1")
    expect(commands()).toEqual([["Fetch.enable", documentsOf("https://staging.test")]])

    expect(event("Fetch.requestPaused", { requestId: "request" })).toEqual([
      "Fetch.continueRequest",
      { requestId: "request" },
      "session"
    ])
    expect(event("Fetch.authRequired", challenge("https://staging.test"))?.[1]).toEqual(
      answer("request", { response: "CancelAuth" })
    )
    expect(visiting.failure(undefined)?.message).toContain(signInNeeded)

    await visiting.end()
    expect(commands().at(-1)).toEqual(["Fetch.disable", {}])
    expect(event("Fetch.authRequired", challenge("https://staging.test"))?.[1]).toEqual(
      answer("request", { response: "CancelAuth" })
    )
  })

  it("answers with the credentials given for the origin, once, and keeps them for the tab", async () => {
    const { commands, event, visit } = fixture()
    const visiting = await visit("https://staging.test/admin", { httpCredentials: credentials })
    expect(event("Fetch.authRequired", challenge("https://staging.test"))?.[1]).toEqual(
      answer("request", { response: "ProvideCredentials", ...credentials })
    )
    expect(visiting.failure(undefined)).toBeUndefined()
    expect(event("Fetch.authRequired", challenge("https://staging.test"))?.[1]).toEqual(
      answer("request", { response: "CancelAuth" })
    )
    expect(visiting.failure(undefined)?.message).toContain(signInNeeded)

    await visiting.end()
    expect(commands().at(-1)).toEqual(["Fetch.enable", documentsOf("https://staging.test")])

    const elsewhere = await visit("https://other.test/")
    expect(commands().at(-1)).toEqual([
      "Fetch.enable",
      documentsOf("https://staging.test", "https://other.test")
    ])
    expect(event("Fetch.authRequired", challenge("https://other.test", "other"))?.[1]).toEqual(
      answer("other", { response: "CancelAuth" })
    )
    expect(event("Fetch.authRequired", challenge("https://staging.test", "again"))?.[1]).toEqual(
      answer("again", { response: "ProvideCredentials", ...credentials })
    )
    expect(
      event("Fetch.authRequired", challenge("https://staging.test", "proxy", "Proxy"))?.[1]
    ).toEqual(answer("proxy", { response: "Default" }))
    await elsewhere.end()
  })

  it("leaves other tabs and non-web addresses alone, and forgets a tab when it detaches", async () => {
    const { commands, event, visit } = fixture()
    const blank = await visit("about:blank")
    expect(commands()).toEqual([])
    expect(blank.failure("net::ERR_FAILED")?.message).toBe("net::ERR_FAILED")

    await visit("https://staging.test/", { httpCredentials: credentials })
    expect(event("Fetch.requestPaused", { requestId: "request" }, "other-session")).toBeUndefined()
    event("Target.detachedFromTarget", { sessionId: "session" }, "browser")
    expect(event("Fetch.authRequired", challenge("https://staging.test"))).toBeUndefined()
  })

  it("rejects credentials it can't use and sends nothing", async () => {
    const { sent, visit } = fixture()
    await expect(
      visit("https://staging.test/", { httpCredentials: { username: "user" } })
    ).rejects.toThrow("httpCredentials must be { username, password }")
    await expect(visit("not a url", { httpCredentials: credentials })).rejects.toThrow(
      "need a full http(s) URL"
    )
    expect(sent).toEqual([])
  })
})

describe("Untrusted certificates", () => {
  it("proceeds for the trusted host only, and explains the ones it refused", async () => {
    const { commands, event, visit } = fixture()
    const visiting = await visit("https://staging.test:8443/", { ignoreCertificateErrors: true })
    expect(commands().slice(1)).toEqual([
      ["Security.enable", {}],
      ["Security.setOverrideCertificateErrors", { override: true }]
    ])

    expect(
      event("Security.certificateError", certificateError("https://staging.test:8443/a"))
    ).toEqual(["Security.handleCertificateError", { eventId: 7, action: "continue" }, "session"])
    expect(visiting.failure("net::ERR_ABORTED")?.message).toBe("net::ERR_ABORTED")

    expect(
      event("Security.certificateError", certificateError("https://staging.test/", 9))?.[1]
    ).toEqual({ eventId: 9, action: "cancel" })
    expect(visiting.failure("net::ERR_ABORTED")?.message).toContain(
      "The site's certificate isn't trusted (net::ERR_CERT_AUTHORITY_INVALID)"
    )
    expect(visiting.failure(undefined)).toBeUndefined()
  })

  it("leaves an error page first when the browser can't change certificate handling there", async () => {
    const { commands, visit } = fixture(["Security.enable"])
    await visit("https://staging.test/", { ignoreCertificateErrors: true })
    expect(commands().slice(1)).toEqual([
      ["Security.enable", {}],
      ["Page.navigate", { url: "about:blank" }],
      ["Runtime.evaluate", expect.anything()],
      ["Security.enable", {}],
      ["Security.setOverrideCertificateErrors", { override: true }]
    ])
  })

  it("tells the agent how to get past a refused login or certificate", async () => {
    const { visit } = fixture()
    const visiting = await visit("https://a.test/")
    expect(visiting.failure("net::ERR_INVALID_AUTH_CREDENTIALS")?.message).toContain(
      "tab.goto(url, { httpCredentials: { username, password } })"
    )
    expect(visiting.failure("net::ERR_CERT_DATE_INVALID")?.message).toContain(
      "tab.goto(url, { ignoreCertificateErrors: true })"
    )
    expect(visiting.failure("net::ERR_FAILED")?.message).toBe("net::ERR_FAILED")
  })
})

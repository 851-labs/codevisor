import { describe, expect, it } from "vitest"
import {
  makePaneTokenStore,
  paneCookieHeader,
  paneCookieName,
  readCookieValue,
  stripPaneCookie
} from "./plugin-pane-auth.js"

const scope = { paneId: "pane-1", paneType: "main", pluginId: "owner.example" }

describe("makePaneTokenStore", () => {
  it("issues tokens that verify for the owning plugin", () => {
    const store = makePaneTokenStore()
    const issued = store.issue({ ...scope, cwd: "/tmp", themeMode: "dark", workspaceId: "w1" })
    expect(issued.token.length).toBeGreaterThan(20)
    const verified = store.verify(issued.token, "owner.example")
    expect(verified?.paneId).toBe("pane-1")
    expect(verified?.cwd).toBe("/tmp")
  })

  it("rejects unknown tokens and cross-plugin use", () => {
    const store = makePaneTokenStore()
    const issued = store.issue(scope)
    expect(store.verify("nope", "owner.example")).toBeUndefined()
    expect(store.verify(issued.token, "other.plugin")).toBeUndefined()
  })

  it("expires initial tokens and sweeps them on issue", () => {
    let current = 0
    const store = makePaneTokenStore(() => current)
    const issued = store.issue(scope)
    current = 11 * 60_000
    expect(store.verify(issued.token, "owner.example")).toBeUndefined()
    // A second expired token is removed by the sweep on the next issue.
    const second = store.issue(scope)
    current = 30 * 60_000
    store.issue(scope)
    expect(store.verify(second.token, "owner.example")).toBeUndefined()
  })

  it("keeps live tokens through the issue-time sweep", () => {
    const store = makePaneTokenStore()
    const first = store.issue(scope)
    const second = store.issue(scope)
    expect(store.verify(first.token, "owner.example")).toBeDefined()
    expect(store.verify(second.token, "owner.example")).toBeDefined()
  })

  it("extends established sessions far beyond the initial TTL", () => {
    let current = 0
    const store = makePaneTokenStore(() => current)
    const issued = store.issue(scope)
    store.establishSession(issued.token)
    current = 6 * 60 * 60_000
    expect(store.verify(issued.token, "owner.example")).toBeDefined()
  })

  it("ignores establishSession for unknown tokens", () => {
    const store = makePaneTokenStore()
    store.establishSession("missing")
  })

  it("slides the expiry window on verify", () => {
    let current = 0
    const store = makePaneTokenStore(() => current)
    const issued = store.issue(scope)
    current = 9 * 60_000
    expect(store.verify(issued.token, "owner.example")).toBeDefined()
    current = 18 * 60_000
    expect(store.verify(issued.token, "owner.example")).toBeDefined()
  })

  it("signs context payloads deterministically per store", () => {
    const store = makePaneTokenStore()
    expect(store.signContext("payload")).toBe(store.signContext("payload"))
    expect(store.signContext("payload")).not.toBe(store.signContext("other"))
  })
})

describe("cookie helpers", () => {
  it("flattens plugin ids into safe cookie names", () => {
    expect(paneCookieName("owner.example")).toBe("codevisor-plugin-owner-example")
  })

  it("builds a plugin-scoped HttpOnly cookie", () => {
    const header = paneCookieHeader("owner.example", "token123")
    expect(header).toContain("codevisor-plugin-owner-example=token123")
    expect(header).toContain("Path=/v1/plugins/owner.example/")
    expect(header).toContain("HttpOnly")
  })

  it("reads cookie values out of a header", () => {
    const name = paneCookieName("owner.example")
    expect(readCookieValue(`a=1; ${name}=tok; b=2`, name)).toBe("tok")
    expect(readCookieValue("a=1", name)).toBeUndefined()
    expect(readCookieValue(undefined, name)).toBeUndefined()
    expect(readCookieValue("malformed", name)).toBeUndefined()
  })

  it("strips only our pane cookie from forwarded headers", () => {
    const name = paneCookieName("owner.example")
    expect(stripPaneCookie(`a=1; ${name}=tok; b=2`, name)).toBe("a=1; b=2")
    expect(stripPaneCookie(`${name}=tok`, name)).toBeUndefined()
    expect(stripPaneCookie(undefined, name)).toBeUndefined()
  })
})

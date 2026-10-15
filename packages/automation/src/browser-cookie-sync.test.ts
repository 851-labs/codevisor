import {
  browserCookieKey,
  type BrowserCookie,
  type BrowserCookieEntry,
  type BrowserCookieMutation
} from "@codevisor/api"
import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"

import { synchronizeManagedCookies } from "./browser-cookie-sync.js"
import { fakeCdpConnection } from "./browser-runtime-test-support.js"
import { expectString, optionalString, recordsIn } from "./unknown-values.js"

const cookie = (value = "login"): BrowserCookie => ({
  name: "session",
  value,
  domain: "example.test",
  path: "/",
  secure: true,
  httpOnly: true,
  sameSite: "lax"
})
const jarKey = (raw: Readonly<Record<string, unknown>>): string =>
  browserCookieKey({
    domain: expectString(raw.domain, "cookie domain"),
    path: optionalString(raw.path) ?? "",
    name: optionalString(raw.name) ?? ""
  })
const firstCookieName = (params: Readonly<Record<string, unknown>> | undefined) =>
  recordsIn(params?.cookies)[0]?.name
const fixture = () => {
  let jar: Record<string, unknown>[] = []
  const entries = new Map<string, BrowserCookieEntry>()
  let revision = 0
  let beforeReply: (() => void | Promise<void>) | undefined
  const change = (changed: BrowserCookie | null, key = browserCookieKey(changed!)) =>
    entries.set(key, { key, revision: ++revision, cookie: changed })
  const exchange = vi.fn((mutations: ReadonlyArray<BrowserCookieMutation>) =>
    Effect.promise(async () => {
      for (const mutation of mutations)
        if ((entries.get(mutation.key)?.revision ?? 0) === mutation.expectedRevision)
          change(mutation.cookie, mutation.key)
      const snapshot = { revision, entries: [...entries.values()] }
      const hook = beforeReply
      beforeReply = undefined
      await hook?.()
      return snapshot
    })
  )
  const send = vi.fn(async (method: string, params: Readonly<Record<string, unknown>> = {}) => {
    if (method === "Storage.getCookies") return { cookies: structuredClone(jar) }
    for (const raw of recordsIn(params.cookies)) {
      const normalized: Record<string, unknown> = {
        ...raw,
        domain: raw.domain ?? new URL(String(raw.url)).hostname
      }
      delete normalized.url
      const key = jarKey(normalized)
      jar = jar.filter((item) => typeof item.domain !== "string" || jarKey(item) !== key)
      if (raw.expires !== 1) jar.push(normalized)
    }
    return {}
  })
  return {
    entries,
    exchange,
    send,
    change,
    get jar() {
      return jar
    },
    set jar(value) {
      jar = value
    },
    hook(callback: () => void | Promise<void>) {
      beforeReply = callback
    },
    start: () =>
      synchronizeManagedCookies(fakeCdpConnection({ send }).connection, {
        exchangeBrowserCookies: exchange
      })
  }
}
afterEach(() => vi.useRealTimers())

describe("managed Chromium cookie synchronization", () => {
  it("pulls the shared session before use, preserves attributes, publishes rotations and consumes logout", async () => {
    const f = fixture()
    f.change(cookie())
    f.change({
      ...cookie(),
      name: "domain",
      domain: ".example.test",
      secure: false,
      sameSite: "none",
      expires: 4_000_000_000
    })
    f.change({ ...cookie(), name: "plain", sameSite: "unspecified", secure: false })
    const sync = await f.start()
    try {
      expect(f.jar).toHaveLength(3)
      expect(f.send).toHaveBeenCalledWith("Storage.setCookies", {
        cookies: [
          expect.objectContaining({ url: "https://example.test/", httpOnly: true, sameSite: "Lax" })
        ]
      })
      expect(f.send).toHaveBeenCalledWith("Storage.setCookies", {
        cookies: [
          expect.objectContaining({
            domain: ".example.test",
            expires: 4_000_000_000,
            sameSite: "None"
          })
        ]
      })
      f.jar = [cookie("rotated")]
      await sync.synchronize()
      expect(f.entries.get(browserCookieKey(cookie()))?.cookie?.value).toBe("rotated")
      expect(f.entries.get(browserCookieKey({ ...cookie(), name: "domain" }))?.cookie).toBeNull()
      f.change(null, browserCookieKey(cookie()))
      await sync.synchronize()
      expect(f.jar).toEqual([])
      const published = f.exchange.mock.calls.flatMap(([changes]) => changes).length
      await sync.synchronize()
      expect(f.exchange.mock.calls.flatMap(([changes]) => changes)).toHaveLength(published)
    } finally {
      sync.stop()
    }
  })
  it("adopts unknown cookies, excludes partitioned/invalid cookies, and respects persisted deletion on restart", async () => {
    const f = fixture()
    f.jar = [
      cookie(),
      { ...cookie(), name: "defaults", path: undefined, sameSite: undefined, expires: -1 },
      { ...cookie(), name: "future", sameSite: "Extended" },
      { ...cookie(), name: "partition", partitionKey: {} },
      { ...cookie(), name: "opaque", partitionKeyOpaque: true },
      { value: "x", domain: "example.test" },
      { name: "x", domain: "example.test" },
      { name: "x", value: "y" }
    ]
    let sync = await f.start()
    sync.stop()
    expect([...f.entries.values()].filter((entry) => entry.cookie)).toHaveLength(3)
    expect(
      [...f.entries.values()].find((entry) => entry.cookie?.name === "defaults")?.cookie
    ).toMatchObject({ path: "/", sameSite: "unspecified" })
    expect(
      [...f.entries.values()].find((entry) => entry.cookie?.name === "future")?.cookie
    ).toMatchObject({ sameSite: "unspecified" })
    f.change(null, browserCookieKey(cookie()))
    sync = await f.start()
    try {
      expect(f.jar.some((raw) => raw.name === "session")).toBe(false)
    } finally {
      sync.stop()
    }
  })
  it("does not overwrite a page cookie changed during bootstrap or a later server reply", async () => {
    const f = fixture()
    f.jar = [cookie("old")]
    f.change(cookie("server"))
    f.hook(() => {
      f.jar = [cookie("during-bootstrap")]
    })
    const sync = await f.start()
    try {
      expect(f.jar[0]?.value).toBe("during-bootstrap")
      expect(f.entries.get(browserCookieKey(cookie()))?.cookie?.value).toBe("during-bootstrap")
      f.change(cookie("other-client"))
      f.hook(() => {
        f.jar = [cookie("during-reply")]
      })
      await sync.synchronize()
      expect(f.jar[0]?.value).toBe("during-reply")
      await sync.synchronize()
      expect(f.entries.get(browserCookieKey(cookie()))?.cookie?.value).toBe("during-reply")
    } finally {
      sync.stop()
    }
  })
  it("preserves a first login during bootstrap and imports later changes without echo", async () => {
    const f = fixture()
    f.change(cookie("old-server"))
    f.hook(() => {
      f.jar = [cookie("first-login")]
    })
    const sync = await f.start()
    try {
      expect(f.entries.get(browserCookieKey(cookie()))?.cookie?.value).toBe("first-login")
      f.change(cookie("new-server"))
      await sync.synchronize()
      expect(f.jar[0]?.value).toBe("new-server")
      await sync.synchronize()
      expect(f.exchange.mock.calls.at(-1)?.[0]).toEqual([])
    } finally {
      sync.stop()
    }
  })
  it("skips a cookie Chromium rejects without retrying it or deleting the shared copy", async () => {
    const f = fixture()
    const rejected = { ...cookie(), name: "rejected" }
    f.change(rejected)
    f.change(cookie())
    const send = f.send.getMockImplementation()!
    f.send.mockImplementation(async (method, params) => {
      if (method === "Storage.setCookies" && firstCookieName(params) === "rejected")
        throw new Error("Invalid cookie fields")
      return send(method, params)
    })
    const sync = await f.start()
    try {
      expect(f.jar.map((raw) => raw.name)).toEqual(["session"])
      await sync.synchronize()
      const attempts = f.send.mock.calls.filter(
        ([method, params]) =>
          method === "Storage.setCookies" && firstCookieName(params) === "rejected"
      )
      expect(attempts).toHaveLength(1)
      expect(f.entries.get(browserCookieKey(rejected))?.cookie).toEqual(rejected)
      expect(f.exchange.mock.calls.flatMap(([changes]) => changes)).toEqual([])
    } finally {
      sync.stop()
    }
  })
  it("coalesces overlapping sync, retries periodic errors, and stops its timer", async () => {
    vi.useFakeTimers()
    const f = fixture()
    const sync = await f.start()
    try {
      const entered = Promise.withResolvers<void>()
      const release = Promise.withResolvers<void>()
      f.hook(() => {
        entered.resolve()
        return release.promise
      })
      const first = sync.synchronize()
      await entered.promise
      expect(sync.synchronize()).toBe(first)
      release.resolve()
      await first
      f.send.mockRejectedValueOnce(Error("temporarily disconnected"))
      await vi.advanceTimersByTimeAsync(2000)
      f.jar = [cookie()]
      await vi.advanceTimersByTimeAsync(2000)
      expect(f.entries.get(browserCookieKey(cookie()))?.cookie).toEqual(cookie())
      sync.stop()
      const calls = f.send.mock.calls.length
      await sync.synchronize()
      await vi.advanceTimersByTimeAsync(4000)
      expect(f.send).toHaveBeenCalledTimes(calls)
    } finally {
      sync.stop()
    }
  })
})

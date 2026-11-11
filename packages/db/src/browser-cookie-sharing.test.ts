import {
  browserCookieKey,
  maxSharedBrowserCookiesPerCall,
  type BrowserCookie,
  type BrowserCookieSnapshot
} from "@codevisor/api"
import { afterEach, beforeEach, describe, expect, it, onTestFinished, vi } from "vitest"

import { makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const cookie = (domain: string, name = "session", value = "fixture-value"): BrowserCookie => ({
  name,
  value,
  domain,
  path: "/",
  httpOnly: true,
  secure: true,
  sameSite: "lax"
})

const open = async (serverId: string): Promise<CodevisorDatabaseService> => {
  const db = await run(makeDatabase({ filename: tempDatabase(), serverId }))
  onTestFinished(() => run(db.close))
  return db
}

const write = (db: CodevisorDatabaseService, ...cookies: BrowserCookie[]) =>
  run(
    db.exchangeBrowserCookies(
      cookies.map((value) => ({ key: browserCookieKey(value), expectedRevision: 0, cookie: value }))
    )
  )

const shareInto = async (from: CodevisorDatabaseService, to: CodevisorDatabaseService) =>
  run(to.mergeSharedBrowserCookies((await run(from.sharedBrowserCookiesAfter(0))).entries))

const live = (snapshot: BrowserCookieSnapshot) =>
  Object.fromEntries(
    snapshot.entries.flatMap((entry) =>
      entry.cookie === null ? [] : [[entry.key, entry.cookie.value]]
    )
  )

const jar = async (db: CodevisorDatabaseService) => live(await run(db.exchangeBrowserCookies([])))

describe("shared browser cookies", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(new Date("2026-11-10T00:00:00Z"))
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it("shares sign-ins for public sites and keeps local hosts on their machine", async () => {
    const laptop = await open("laptop")
    const studio = await open("studio")
    await write(laptop, cookie(".github.com"), cookie("localhost"), cookie("192.168.1.4"))

    expect(await shareInto(laptop, studio)).toBe(1)
    expect(await jar(studio)).toEqual({
      [browserCookieKey(cookie(".github.com"))]: "fixture-value"
    })
    expect(await run(laptop.browserCookieShareRevision)).toBeGreaterThan(0)
  })

  it("lets the newest change win and carries sign-outs to the other machine", async () => {
    const laptop = await open("laptop")
    const studio = await open("studio")
    const signedIn = await write(laptop, cookie("github.com", "session", "laptop"))
    vi.setSystemTime(new Date("2026-11-10T00:01:00Z"))
    await write(studio, cookie("github.com", "session", "studio"))

    expect(await shareInto(laptop, studio)).toBe(0)
    await shareInto(studio, laptop)
    expect(Object.values(await jar(laptop))).toEqual(["studio"])

    vi.setSystemTime(new Date("2026-11-10T00:02:00Z"))
    const key = browserCookieKey(cookie("github.com"))
    const current = (await run(laptop.exchangeBrowserCookies([]))).entries[0]!
    expect(current.revision).toBeGreaterThan(signedIn.revision)
    await run(
      laptop.exchangeBrowserCookies([{ key, expectedRevision: current.revision, cookie: null }])
    )
    await shareInto(laptop, studio)
    expect(await jar(studio)).toEqual({})
  })

  it("ignores shared cookies for local hosts and malformed entries", async () => {
    const studio = await open("studio")
    const stamp = { wallMs: 1, counter: 0, deviceId: "laptop" }
    const local = cookie("localhost")
    const github = cookie("github.com")

    const merged = await run(
      studio.mergeSharedBrowserCookies([
        { key: browserCookieKey(local), cookie: local, stamp },
        { key: "wrong-key", cookie: github, stamp },
        { key: browserCookieKey(github), cookie: github, stamp }
      ])
    )

    expect(merged).toBe(1)
    expect(Object.keys(await jar(studio))).toEqual([browserCookieKey(github)])
  })

  it("pages through large jars and restarts after the other machine resets", async () => {
    const laptop = await open("laptop")
    const many = Array.from({ length: maxSharedBrowserCookiesPerCall + 5 }, (_, index) =>
      cookie("github.com", `cookie-${index}`)
    )
    const written = await write(laptop, ...many)

    const first = await run(laptop.sharedBrowserCookiesAfter(0))
    const rest = await run(laptop.sharedBrowserCookiesAfter(first.revision))

    expect([first.more, first.entries.length]).toEqual([true, maxSharedBrowserCookiesPerCall])
    expect([rest.more, rest.entries.length, rest.revision]).toEqual([false, 5, written.revision])
    expect((await run(laptop.sharedBrowserCookiesAfter(written.revision + 50))).more).toBe(true)
  })

  it("replaces every site Chrome has and leaves other sites alone", async () => {
    const studio = await open("studio")
    await write(
      studio,
      cookie(".github.com", "old-session"),
      cookie("gist.github.com", "gist"),
      cookie("example.com", "kept"),
      cookie("localhost", "dev")
    )

    const result = await run(
      studio.importBrowserCookies([
        cookie("github.com", "session", "chrome"),
        cookie("localhost", "chrome-dev")
      ])
    )

    expect(result).toEqual({ imported: 1, replaced: 2 })
    expect(Object.values(await jar(studio)).toSorted()).toEqual([
      "chrome",
      "fixture-value",
      "fixture-value"
    ])
    expect(Object.keys(await jar(studio))).not.toContain(
      browserCookieKey(cookie(".github.com", "old-session"))
    )
  })

  it("remembers how far each machine has shared", async () => {
    const studio = await open("studio")
    expect(await run(studio.getBrowserCookiePeerCursor("laptop"))).toEqual({ sent: 0, seen: 0 })

    await run(studio.setBrowserCookiePeerCursor("laptop", { sent: 4, seen: 9 }))

    expect(await run(studio.getBrowserCookiePeerCursor("laptop"))).toEqual({ sent: 4, seen: 9 })
    expect(await run(studio.getBrowserCookiePeerCursor("phone"))).toEqual({ sent: 0, seen: 0 })
  })
})

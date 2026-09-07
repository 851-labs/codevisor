import { browserCookieKey, type BrowserCookie } from "@codevisor/api"
import { describe, expect, it, vi } from "vitest"
import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const cookie: BrowserCookie = {
  name: "session",
  value: "fixture-session",
  domain: "localhost",
  path: "/",
  httpOnly: true,
  secure: false,
  sameSite: "lax"
}
const key = browserCookieKey(cookie)

describe("shared browser state", () => {
  it("merges independent changes and preserves logout tombstones across restart", async () => {
    const filename = tempDatabase()
    let db = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      const login = await run(db.exchangeBrowserCookies([{ key, expectedRevision: 0, cookie }]))
      const preferences = { ...cookie, name: "theme", value: "dark" }
      const merged = await run(
        db.exchangeBrowserCookies([
          { key: browserCookieKey(preferences), expectedRevision: 0, cookie: preferences }
        ])
      )
      expect(merged.entries).toHaveLength(2)
      expect(
        await run(db.exchangeBrowserCookies([{ key, expectedRevision: login.revision, cookie }]))
      ).toEqual(merged)
      const logout = await run(
        db.exchangeBrowserCookies([
          { key, expectedRevision: login.entries[0]!.revision, cookie: null }
        ])
      )
      await run(db.close)
      db = await run(makeDatabase({ filename, serverId: "local" }))
      const stale = await run(
        db.exchangeBrowserCookies([{ key, expectedRevision: login.entries[0]!.revision, cookie }])
      )
      expect(stale).toEqual(logout)
      const firstLaunch = await run(
        db.exchangeBrowserCookies([{ key, expectedRevision: 0, cookie }])
      )
      expect(firstLaunch).toEqual(logout)
    } finally {
      await run(db.close)
    }
  })
  it("expires cookies without allowing an old device to resurrect them", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(new Date("2026-01-01T00:00:00Z"))
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const expires = Date.now() / 1000 + 60
      const first = await run(
        db.exchangeBrowserCookies([{ key, expectedRevision: 0, cookie: { ...cookie, expires } }])
      )
      vi.setSystemTime(new Date("2026-01-01T00:01:00Z"))
      const next = await run(
        db.exchangeBrowserCookies([
          { key, expectedRevision: first.revision, cookie: { ...cookie, expires } }
        ])
      )
      expect(next.entries[0]?.cookie).toBeNull()
      expect(next.revision).toBe(first.revision + 1)
    } finally {
      await run(db.close)
      vi.useRealTimers()
    }
  })
  it("retains the last ordinary navigation and excludes OAuth callback secrets", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      expect(await run(db.getBrowserNavigation("pane"))).toBeUndefined()
      const nav = { url: "https://example.test/account", title: "Account" }
      await run(db.setBrowserNavigation("pane", nav))
      for (const url of [
        "https://example.test/callback?code=fixture",
        "https://example.test/#access_token=fixture",
        "javascript:alert(1)"
      ]) {
        await run(db.setBrowserNavigation("pane", { url, title: "Callback" }))
        expect(await run(db.getBrowserNavigation("pane"))).toEqual(nav)
      }
      expect(await run(db.getBrowserNavigation("another-pane"))).toBeUndefined()
    } finally {
      await run(db.close)
    }
  })
  it("rejects malformed mutations atomically", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      await expect(
        run(
          db.exchangeBrowserCookies([
            { key, expectedRevision: 0, cookie },
            { key: "wrong-key", expectedRevision: 0, cookie }
          ])
        )
      ).rejects.toThrow("Invalid cookie")
      for (const invalid of [
        { key: "x".repeat(8193), expectedRevision: 0, cookie },
        { key, expectedRevision: 0.5, cookie },
        { key, expectedRevision: -1, cookie }
      ])
        await expect(run(db.exchangeBrowserCookies([invalid]))).rejects.toThrow(
          "Invalid cookie revision or key"
        )
      await expect(
        run(
          db.exchangeBrowserCookies(
            Array.from({ length: 20_001 }, () => ({ key, expectedRevision: 0, cookie }))
          )
        )
      ).rejects.toThrow("Too many cookie changes")
      expect((await run(db.exchangeBrowserCookies([]))).entries).toEqual([])
    } finally {
      await run(db.close)
    }
  })
})

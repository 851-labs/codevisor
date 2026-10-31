import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { HarnessUsageLimits } from "@codevisor/api"
import { describe, expect, it, onTestFinished, vi } from "vitest"

import {
  makeUsageLimitsCache,
  makeUsageLimitsFileStore,
  type UsageLimitsStore
} from "./usage-limits-cache.js"

const limits = (usedPercent: number): HarnessUsageLimits => ({
  fetchedAt: `2026-10-18T00:00:${String(usedPercent).padStart(2, "0")}.000Z`,
  harnessId: "claude-code",
  state: "available",
  windows: [{ id: "five-hour", label: "5-hour limit", usedPercent }]
})

const unavailable: HarnessUsageLimits = {
  detail: "Claude usage request timed out",
  fetchedAt: "2026-10-18T00:01:00.000Z",
  harnessId: "claude-code",
  state: "unavailable",
  windows: []
}

const observed = (id: string, usedPercent: number): HarnessUsageLimits => ({
  ...limits(usedPercent),
  windows: [{ id, label: id, usedPercent }]
})

describe("@codevisor/server usage limits cache", () => {
  it("serves one account snapshot to every caller until it expires", async () => {
    let clock = 0
    const cache = makeUsageLimitsCache({ now: () => clock, ttlMs: 1000 })
    const fetch = vi.fn(async () => limits(fetch.mock.calls.length))

    const [first, second] = await Promise.all([
      cache.read("claude-code:account", fetch),
      cache.read("claude-code:account", fetch)
    ])
    expect(first).toBe(second)
    clock = 999
    expect(await cache.read("claude-code:account", fetch)).toBe(first)
    expect(fetch).toHaveBeenCalledOnce()

    clock = 1000
    expect(await cache.read("claude-code:account", fetch)).toMatchObject({
      windows: [{ usedPercent: 2 }]
    })
    expect(await cache.read("claude-code:other", fetch)).toMatchObject({
      windows: [{ usedPercent: 3 }]
    })
  })

  it("keeps the last available snapshot when a refresh comes back unavailable", async () => {
    let clock = 0
    const cache = makeUsageLimitsCache({ now: () => clock, ttlMs: 1000 })
    const good = limits(42)

    await cache.read("codex:account", async () => good)
    clock = 1000
    const failing = vi.fn(async () => unavailable)
    expect(await cache.read("codex:account", failing)).toBe(good)
    clock = 1500
    expect(await cache.read("codex:account", failing)).toBe(good)
    expect(failing).toHaveBeenCalledOnce()

    expect(await cache.read("codex:fresh", failing)).toBe(unavailable)
    expect(await cache.read("codex:fresh", failing)).toBe(unavailable)
    expect(failing).toHaveBeenCalledTimes(2)
  })

  it("folds live observations into the cached account snapshot", async () => {
    let clock = 0
    const cache = makeUsageLimitsCache({ now: () => clock, ttlMs: 1000 })
    const fetch = vi.fn(async () => ({
      ...limits(10),
      plan: "max",
      windows: [
        { id: "five-hour", label: "5-hour limit", usedPercent: 10 },
        { id: "seven-day", label: "Weekly limit", usedPercent: 20 }
      ]
    }))
    cache.observe("claude-code:account", observed("seven-day", 99), true)
    await cache.read("claude-code:account", fetch)
    cache.observe("claude-code:account", observed("seven-day", 35), true)
    cache.observe("claude-code:account", unavailable, false)
    expect(await cache.read("claude-code:account", fetch)).toMatchObject({
      plan: "max",
      windows: [
        { id: "five-hour", usedPercent: 10 },
        { id: "seven-day", usedPercent: 35 }
      ]
    })

    clock = 999
    cache.observe("claude-code:account", observed("five-hour", 12), false)
    clock = 1500
    expect(await cache.read("claude-code:account", fetch)).toMatchObject({
      plan: "max",
      windows: [{ id: "five-hour", usedPercent: 12 }]
    })
    expect(fetch).toHaveBeenCalledOnce()
  })

  it("serves an account's last known limits after a restart until their windows reset", async () => {
    const savedMuse = Promise.withResolvers<void>()
    let stored: Awaited<ReturnType<UsageLimitsStore["load"]>> = new Map()
    const memory: UsageLimitsStore = {
      load: async () => stored,
      save: async (entries) => {
        stored = new Map(entries)
        if (entries.has("muse-code:account")) savedMuse.resolve()
      }
    }
    let clock = Date.parse("2026-10-18T00:00:00.000Z")
    const before = makeUsageLimitsCache({ now: () => clock, ttlMs: 1000, store: memory })
    await before.read("codex:account", async () => unavailable)
    before.observe(
      "muse-code:account",
      {
        ...limits(30),
        harnessId: "muse-code",
        windows: [
          {
            id: "window",
            label: "5-hour limit",
            usedPercent: 30,
            resetsAt: "2026-10-18T05:00:00.000Z"
          },
          {
            id: "weekly",
            label: "Weekly limit",
            usedPercent: 9,
            resetsAt: "2026-10-20T00:00:00.000Z"
          }
        ]
      },
      false
    )
    await savedMuse.promise
    expect([...stored.keys()]).toEqual(["muse-code:account"])

    clock += 60 * 60_000
    const after = makeUsageLimitsCache({ now: () => clock, ttlMs: 1000, store: memory })
    const empty = vi.fn(async () => ({ ...unavailable, harnessId: "muse-code" }))
    expect(await after.read("muse-code:account", empty)).toMatchObject({
      state: "available",
      windows: [
        { id: "window", usedPercent: 30 },
        { id: "weekly", usedPercent: 9 }
      ]
    })

    clock = Date.parse("2026-10-18T06:00:00.000Z")
    expect(await after.read("muse-code:account", empty)).toMatchObject({
      windows: [{ id: "weekly", usedPercent: 9 }]
    })
    clock = Date.parse("2026-10-21T00:00:00.000Z")
    expect(await after.read("muse-code:account", empty)).toMatchObject({ state: "unavailable" })
  })

  it("stores limits in a file that survives a corrupt or missing copy", async () => {
    const dir = mkdtempSync(join(tmpdir(), "codevisor-usage-limits-"))
    onTestFinished(() => rmSync(dir, { force: true, recursive: true }))
    const path = join(dir, "nested", "usage-limits.json")
    const store = makeUsageLimitsFileStore(path)

    expect(await store.load()).toEqual(new Map())
    const entries = new Map([["codex:account", { checkedAt: 5, limits: limits(12) }]])
    await store.save(entries)
    expect(await store.load()).toEqual(entries)

    writeFileSync(path, "{not json")
    expect(await store.load()).toEqual(new Map())
    writeFileSync(path, JSON.stringify({ version: 2, entries: {} }))
    expect(await store.load()).toEqual(new Map())
  })

  it("keeps serving from memory when its store fails, then writes the latest state", async () => {
    const saves: Array<ReadonlyArray<string>> = []
    const retried = Promise.withResolvers<void>()
    const store: UsageLimitsStore = {
      load: () => Promise.reject(new Error("unreadable")),
      save: async (entries) => {
        saves.push([...entries.keys()])
        if (saves.length === 1) throw new Error("disk full")
        retried.resolve()
      }
    }
    const cache = makeUsageLimitsCache({ store })

    cache.observe("codex:first", limits(1), false)
    cache.observe("codex:second", limits(2), false)
    await retried.promise

    expect(saves).toEqual([["codex:first"], ["codex:first", "codex:second"]])
    const fetch = vi.fn(async () => unavailable)
    expect(await cache.read("codex:second", fetch)).toMatchObject({ windows: [{ usedPercent: 2 }] })
    expect(fetch).not.toHaveBeenCalled()
  })

  it("prefers a live observation over the copy it is still loading from disk", async () => {
    const store: UsageLimitsStore = {
      load: async () => new Map([["codex:account", { checkedAt: Date.now(), limits: limits(10) }]]),
      save: async () => undefined
    }
    const cache = makeUsageLimitsCache({ store })

    cache.observe("codex:account", limits(50), false)

    const fetch = vi.fn(async () => unavailable)
    expect(await cache.read("codex:account", fetch)).toMatchObject({
      windows: [{ usedPercent: 50 }]
    })
    expect(fetch).not.toHaveBeenCalled()
  })
})

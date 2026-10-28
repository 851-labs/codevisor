import { describe, expect, it, vi } from "vitest"

import { makeDirectoryShellEnvCache } from "./shell-env.js"

const probeCounter = () => {
  const probes: Array<string> = []
  const resolve = async (directory: string) => {
    probes.push(directory)
    return { PATH: `${directory}:${probes.length}` }
  }
  return { probes, resolve }
}

describe("makeDirectoryShellEnvCache", () => {
  it("probes each directory once and shares the result", async () => {
    const { probes, resolve } = probeCounter()
    const cache = makeDirectoryShellEnvCache(resolve)
    const [first, second] = await Promise.all([cache.current("/a"), cache.current("/a")])
    const other = await cache.current("/b")
    expect([first.PATH, second.PATH, other.PATH]).toEqual(["/a:1", "/a:1", "/b:2"])
    expect(probes).toEqual(["/a", "/b"])
  })

  it("serves a stale env while one background probe replaces it", async () => {
    let clock = 0
    const { probes, resolve } = probeCounter()
    const cache = makeDirectoryShellEnvCache(resolve, { maxAgeMs: 100, now: () => clock })
    await cache.current("/a")
    clock = 100
    const [stale, alsoStale] = await Promise.all([cache.current("/a"), cache.current("/a")])
    expect([stale.PATH, alsoStale.PATH, probes.length]).toEqual(["/a:1", "/a:1", 2])
    await vi.waitFor(async () => expect((await cache.current("/a")).PATH).toBe("/a:2"))
    expect(probes.length).toBe(2)
  })

  it("keeps the stale env and retries later when a background probe fails", async () => {
    let clock = 0
    let fail = false
    let probes = 0
    const cache = makeDirectoryShellEnvCache(
      async () => {
        probes += 1
        if (fail) throw new Error("shell timed out")
        return { PATH: `/probe-${probes}` }
      },
      { maxAgeMs: 100, now: () => clock }
    )
    await cache.current("/a")
    clock = 100
    fail = true
    expect((await cache.current("/a")).PATH).toBe("/probe-1")
    await vi.waitFor(() => expect(probes).toBe(2))
    fail = false
    await vi.waitFor(async () => expect((await cache.current("/a")).PATH).toBe("/probe-3"))
  })

  it("forgets a failed first probe so the next reader probes again", async () => {
    let probes = 0
    const cache = makeDirectoryShellEnvCache(async () => {
      probes += 1
      if (probes === 1) throw new Error("shell timed out")
      return { PATH: "/ok" }
    })
    await expect(cache.current("/a")).rejects.toThrow("shell timed out")
    expect((await cache.current("/a")).PATH).toBe("/ok")
  })

  it("keeps a newer probe when a first probe from before clear fails", async () => {
    const firstProbe = Promise.withResolvers<NodeJS.ProcessEnv>()
    let probes = 0
    const cache = makeDirectoryShellEnvCache((directory) => {
      probes += 1
      if (probes === 1) return firstProbe.promise
      return Promise.resolve({ PATH: directory })
    })
    const first = cache.current("/a")
    cache.clear()
    expect((await cache.current("/a")).PATH).toBe("/a")
    firstProbe.reject(new Error("shell timed out"))
    await expect(first).rejects.toThrow("shell timed out")
    expect((await cache.current("/a")).PATH).toBe("/a")
    expect(probes).toBe(2)
  })

  it("probes again after clear and drops background results from before it", async () => {
    let clock = 0
    const revalidation = Promise.withResolvers<NodeJS.ProcessEnv>()
    let probes = 0
    const cache = makeDirectoryShellEnvCache(
      (directory) => {
        probes += 1
        if (probes === 2) return revalidation.promise
        return Promise.resolve({ PATH: `${directory}:${probes}` })
      },
      { maxAgeMs: 100, now: () => clock }
    )
    await cache.current("/a")
    clock = 100
    await cache.current("/a")
    cache.clear()
    expect((await cache.current("/a")).PATH).toBe("/a:3")
    revalidation.resolve({ PATH: "/a:stale" })
    await Promise.resolve()
    expect((await cache.current("/a")).PATH).toBe("/a:3")
    expect(probes).toBe(3)
  })

  it("answers a new directory with the fallback env while it probes that directory once", async () => {
    const probe = Promise.withResolvers<NodeJS.ProcessEnv>()
    let probes = 0
    const cache = makeDirectoryShellEnvCache(
      () => {
        probes += 1
        return probe.promise
      },
      { fallback: async () => ({ PATH: "/login" }) }
    )
    const [first, second] = await Promise.all([cache.current("/a"), cache.current("/a")])
    expect([first.PATH, second.PATH, probes]).toEqual(["/login", "/login", 1])
    probe.resolve({ PATH: "/a" })
    await vi.waitFor(async () => expect((await cache.current("/a")).PATH).toBe("/a"))
    expect(probes).toBe(1)
  })

  it("keeps answering with the fallback and probes again after a failed directory probe", async () => {
    let probes = 0
    const cache = makeDirectoryShellEnvCache(
      async () => {
        probes += 1
        if (probes === 1) throw new Error("shell timed out")
        return { PATH: "/a" }
      },
      { fallback: async () => ({ PATH: "/login" }) }
    )
    expect((await cache.current("/a")).PATH).toBe("/login")
    await vi.waitFor(() => expect(probes).toBe(1))
    await Promise.resolve()
    expect((await cache.current("/a")).PATH).toBe("/login")
    await vi.waitFor(async () => expect((await cache.current("/a")).PATH).toBe("/a"))
    expect(probes).toBe(2)
  })

  it("evicts the oldest directories beyond its limit", async () => {
    const { probes, resolve } = probeCounter()
    const cache = makeDirectoryShellEnvCache(resolve, { limit: 2 })
    await cache.current("/a")
    await cache.current("/b")
    await cache.current("/c")
    await cache.current("/b")
    await cache.current("/a")
    expect(probes).toEqual(["/a", "/b", "/c", "/a"])
  })
})

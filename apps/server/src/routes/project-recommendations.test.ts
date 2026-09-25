import { setImmediate as nextMacrotask } from "node:timers/promises"

import { describe, expect, it } from "vitest"

import { makeStaleWhileRevalidate } from "./project-recommendations.js"

/// A load whose results the test hands out one call at a time.
const scriptedLoads = () => {
  const pending: Array<PromiseWithResolvers<ReadonlyArray<string>>> = []
  return {
    load: () => {
      const next = Promise.withResolvers<ReadonlyArray<string>>()
      pending.push(next)
      return next.promise
    },
    get calls() {
      return pending.length
    },
    resolve: (index: number, value: ReadonlyArray<string>) => pending[index]!.resolve(value),
    reject: (index: number) => pending[index]!.reject(new Error("store unavailable"))
  }
}

describe("makeStaleWhileRevalidate", () => {
  it("serves the cached answer while a stale one refreshes in the background", async () => {
    let clock = 0
    const loads = scriptedLoads()
    const get = makeStaleWhileRevalidate(loads.load, () => clock)

    const first = get()
    loads.resolve(0, ["alpha"])
    expect(await first).toEqual(["alpha"])

    clock = 20_000
    expect(await get()).toEqual(["alpha"])
    // A second stale read joins the refresh already running.
    expect(await get()).toEqual(["alpha"])
    expect(loads.calls).toBe(2)

    loads.resolve(1, ["beta"])
    await nextMacrotask()
    expect(await get()).toEqual(["beta"])
    expect(loads.calls).toBe(2)
  })

  it("keeps the last good answer when a background refresh fails", async () => {
    let clock = 0
    const loads = scriptedLoads()
    const get = makeStaleWhileRevalidate(loads.load, () => clock)
    const first = get()
    loads.resolve(0, ["alpha"])
    await first

    clock = 20_000
    expect(await get()).toEqual(["alpha"])
    loads.reject(1)
    await nextMacrotask()

    expect(await get()).toEqual(["alpha"])
    expect(loads.calls).toBe(3)
  })

  it("recomputes an empty stale answer before responding", async () => {
    let clock = 0
    const loads = scriptedLoads()
    const get = makeStaleWhileRevalidate(loads.load, () => clock)
    const first = get()
    loads.resolve(0, [])
    expect(await first).toEqual([])

    clock = 20_000
    const second = get()
    loads.resolve(1, ["alpha"])
    expect(await second).toEqual(["alpha"])
  })
})

import { describe, expect, it, vi } from "vitest"

import { makeOpenCodeServerPool } from "./pool.js"
import type { OpenCodeServer } from "./server.js"

const fakeServer = (url: string) => {
  const stop = vi.fn(async () => undefined)
  return { url, request: vi.fn(), stop } satisfies OpenCodeServer
}

/// Idle countdowns the test fires by hand.
const manualTimers = () => {
  const pending: Array<{ ms: number; run: () => Promise<void>; cancelled: boolean }> = []
  return {
    pending,
    schedule: (ms: number, run: () => Promise<void>) => {
      const timer = { ms, run, cancelled: false }
      pending.push(timer)
      return () => {
        timer.cancelled = true
      }
    },
    /// Fires every live countdown and waits for what it started.
    fire: () =>
      Promise.all(pending.splice(0).flatMap((timer) => (timer.cancelled ? [] : [timer.run()])))
  }
}

describe("OpenCode server pool", () => {
  it("shares one server per key, and stops it only after the last lease has been idle", async () => {
    const timers = manualTimers()
    const pool = makeOpenCodeServerPool({ idleMs: 5_000, schedule: timers.schedule })
    const server = fakeServer("http://a")
    const start = vi.fn(async () => server)

    const [first, second] = await Promise.all([pool.acquire("a", start), pool.acquire("a", start)])
    expect(start).toHaveBeenCalledOnce()
    expect(first.server).toBe(second.server)

    first.release()
    first.release()
    expect(timers.pending).toHaveLength(0)
    second.release()
    expect(timers.pending.map((timer) => timer.ms)).toEqual([5_000])

    // Used again before the countdown ends: the countdown is cancelled.
    const third = await pool.acquire("a", start)
    await timers.fire()
    expect(server.stop).not.toHaveBeenCalled()

    third.release()
    await timers.fire()
    expect(server.stop).toHaveBeenCalledOnce()
    const next = fakeServer("http://a2")
    expect((await pool.acquire("a", async () => next)).server).toBe(next)
  })

  it("never reuses a server that failed to start", async () => {
    const pool = makeOpenCodeServerPool({ schedule: manualTimers().schedule })
    await expect(
      pool.acquire("a", async () => {
        throw new Error("opencode is not installed")
      })
    ).rejects.toThrow("opencode is not installed")
    const server = fakeServer("http://a")
    expect((await pool.acquire("a", async () => server)).server).toBe(server)
  })

  it("stops every server on close, even one still in use", async () => {
    const timers = manualTimers()
    const pool = makeOpenCodeServerPool({ schedule: timers.schedule })
    const busy = fakeServer("http://busy")
    const idle = fakeServer("http://idle")
    await pool.acquire("busy", async () => busy)
    ;(await pool.acquire("idle", async () => idle)).release()
    await pool.close()
    expect(busy.stop).toHaveBeenCalledOnce()
    expect(idle.stop).toHaveBeenCalledOnce()
    await timers.fire()
    expect(idle.stop).toHaveBeenCalledOnce()
  })
})

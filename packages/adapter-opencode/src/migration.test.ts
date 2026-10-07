import { describe, expect, it, vi } from "vitest"

import { pendingOpenCodeMigration } from "./migration.js"
import type { OpenCodeServer } from "./server.js"

/// A server answering the migration status from a script, one per poll.
const server = (statuses: Array<unknown>) => {
  const fake = {
    url: "http://oc",
    stop: vi.fn(async () => undefined),
    request: vi.fn(async (path: string) => {
      expect(path).toBe("/api/experimental/migration/v1")
      const next = statuses.shift()
      if (next instanceof Error) throw next
      return next
    })
  }
  return fake as typeof fake & OpenCodeServer
}

const immediately = async () => undefined

describe("OpenCode 2 data migration", () => {
  it("has nothing to do once OpenCode's data is migrated", async () => {
    const done = server([{ status: "completed" }])
    expect(await pendingOpenCodeMigration({ start: async () => done })).toBeUndefined()
    expect(done.stop).toHaveBeenCalledOnce()
  })

  it("keeps one server up until the migration ends", async () => {
    const waits: Array<number> = []
    const migrating = server([
      { status: "required" },
      { status: "running", progress: { label: "Migrating sessions" } },
      { status: "completed" }
    ])
    const migration = await pendingOpenCodeMigration({
      start: async () => migrating,
      wait: async (ms) => {
        waits.push(ms)
      }
    })
    expect(migrating.stop).not.toHaveBeenCalled()
    await migration!.finish()
    expect(waits).toEqual([1_000, 1_000])
    expect(migrating.request).toHaveBeenCalledTimes(3)
    expect(migrating.stop).toHaveBeenCalledOnce()
  })

  it("fails with OpenCode's reason, and stops the server either way", async () => {
    const failing = server([{ status: "running" }, { status: "error", error: "disk full" }])
    const migration = await pendingOpenCodeMigration({
      start: async () => failing,
      wait: immediately
    })
    await expect(migration!.finish()).rejects.toThrow(
      "OpenCode couldn't migrate its sessions: disk full"
    )
    expect(failing.stop).toHaveBeenCalledOnce()

    const unreachable = server([new Error("connection refused")])
    await expect(pendingOpenCodeMigration({ start: async () => unreachable })).rejects.toThrow(
      "connection refused"
    )
    expect(unreachable.stop).toHaveBeenCalledOnce()

    const dropped = server([{ status: "running" }, new Error("server exited")])
    const interrupted = await pendingOpenCodeMigration({
      start: async () => dropped,
      wait: immediately
    })
    await expect(interrupted!.finish()).rejects.toThrow("server exited")
    expect(dropped.stop).toHaveBeenCalledOnce()
  })

  it("waits a second between checks by default", async () => {
    vi.useFakeTimers()
    try {
      const migrating = server([{ status: "running" }, { status: "completed" }])
      const migration = await pendingOpenCodeMigration({ start: async () => migrating })
      const finished = vi.fn()
      const finishing = migration!.finish().then(finished)
      await vi.advanceTimersByTimeAsync(999)
      expect(finished).not.toHaveBeenCalled()
      await vi.advanceTimersByTimeAsync(1)
      await finishing
      expect(finished).toHaveBeenCalledOnce()
    } finally {
      vi.useRealTimers()
    }
  })
})

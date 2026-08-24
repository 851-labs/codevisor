import type { SyncEntryRecord } from "@codevisor/sync"
import { describe, expect, it } from "vitest"
import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const entry = (
  key: string,
  value: unknown,
  wallMs: number,
  deviceId = "device-a",
  deleted?: boolean
): SyncEntryRecord => ({
  key,
  value,
  ...(deleted === true ? { deleted: true } : {}),
  timestamp: { wallMs, counter: 0, deviceId }
})

describe("sync service", () => {
  it("persists merged entries per namespace with LWW semantics", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "server-a" }))

    expect(await run(db.getSyncEntries("settings"))).toEqual([])

    const first = await run(
      db.mergeSyncEntries("settings", [entry("channel", "stable", 10), entry("theme", "dark", 10)])
    )
    expect(first.changed).toHaveLength(2)

    // A newer write wins; an older one changes nothing.
    const second = await run(
      db.mergeSyncEntries("settings", [entry("channel", "alpha", 20), entry("theme", "light", 5)])
    )
    expect(second.changed).toEqual([entry("channel", "alpha", 20)])
    expect(await run(db.getSyncEntries("settings"))).toEqual([
      entry("channel", "alpha", 20),
      entry("theme", "dark", 10)
    ])

    // Namespaces are isolated.
    expect(await run(db.getSyncEntries("skills"))).toEqual([])

    // Tombstones persist and round-trip.
    const removal = await run(
      db.mergeSyncEntries("settings", [entry("theme", null, 30, "device-b", true)])
    )
    expect(removal.changed).toHaveLength(1)
    expect(await run(db.getSyncEntries("settings"))).toEqual([
      entry("channel", "alpha", 20),
      entry("theme", null, 30, "device-b", true)
    ])

    await run(db.close)
  })
})

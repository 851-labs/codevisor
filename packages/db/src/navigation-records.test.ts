import type { NavigationFolder } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const folder = (revision: string, overrides: Partial<NavigationFolder> = {}): NavigationFolder => ({
  id: "0000000F-0000-0000-0000-000000000001",
  name: "Payments",
  position: "8",
  collapsed: false,
  deleted: false,
  revision,
  ...overrides
})
const at = (ms: number, device = "mac") => `${String(ms).padStart(13, "0")}-000000-${device}`

describe("@codevisor/db replicated navigation records", () => {
  it("keeps the newest revision of each record and ignores replays and older copies", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const first = await run(db.putNavigationRecords({ folders: [folder(at(2))] }))
    expect(first.records).toEqual({
      folders: [{ ...folder(at(2)), id: folder(at(2)).id.toLowerCase() }],
      settings: []
    })
    expect(first.events).toEqual([expect.objectContaining({ kind: "navigation.changed" })])
    // An older copy from another machine loses; the stored record answers.
    const stale = await run(db.putNavigationRecords({ folders: [folder(at(1), { name: "Old" })] }))
    expect(stale.records.folders[0]?.name).toBe("Payments")
    expect(stale.events).toEqual([])
    // A newer tombstone wins and stays listed.
    await run(
      db.putNavigationRecords({ folders: [folder(at(3), { deleted: true, collapsed: true })] })
    )
    expect((await run(db.listNavigationRecords)).folders).toEqual([
      expect.objectContaining({ deleted: true, revision: at(3) })
    ])

    await run(
      db.putNavigationRecords({
        settings: [{ key: "sidebar.grouping", value: "project", revision: at(5, "ios") }]
      })
    )
    await run(
      db.putNavigationRecords({
        settings: [{ key: "sidebar.grouping", value: "none", revision: at(4, "mac") }]
      })
    )
    expect((await run(db.listNavigationRecords)).settings).toEqual([
      { key: "sidebar.grouping", value: "project", revision: at(5, "ios") }
    ])
    await run(db.close)
  })

  it("carries records in the snapshot and in navigation deltas, and omits them while empty", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const empty = await run(db.getNavigationSnapshot)
    expect("folders" in empty).toBe(false)
    expect("settings" in empty).toBe(false)

    const before = await run(db.latestEventCursor)
    await run(
      db.putNavigationRecords({
        folders: [folder(at(1))],
        settings: [{ key: "sidebar.grouping", value: "none", revision: at(1) }]
      })
    )
    const batch = await run(db.readSyncBatch(before))
    const delta = batch.events.find((event) => event.kind === "navigation.changed")
    expect(delta?.payload).toMatchObject({
      folders: [expect.objectContaining({ name: "Payments" })],
      settings: [expect.objectContaining({ key: "sidebar.grouping" })]
    })
    expect(await run(db.getNavigationSnapshot)).toMatchObject({
      folders: [expect.objectContaining({ name: "Payments" })],
      settings: [expect.objectContaining({ value: "none" })]
    })
    await run(db.close)
  })
})

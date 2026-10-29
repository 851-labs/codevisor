import type { Sandbox } from "@codevisor/api"
import type { SyncEntryRecord } from "@codevisor/sync"
import { describe, expect, it } from "vitest"

import { run } from "../server-context.js"
import { makeServices } from "../test-support.js"
import { makeSandboxRecordStore, SANDBOX_RECORDS_NAMESPACE } from "./sandbox-store.js"

const record = (id: string, overrides: Partial<Sandbox> = {}): Sandbox => ({
  id,
  name: id,
  projectId: "project-1",
  provider: "e2b",
  state: "ready",
  createdAt: "2026-10-23T00:00:00.000Z",
  ...overrides
})

const storeOn = async (legacy?: ReadonlyArray<Sandbox>) => {
  const { services } = await makeServices("server-mac")
  if (legacy !== undefined) {
    await run(services.db.setMachineSetting("ephemeral-machines", JSON.stringify(legacy)))
  }
  const changes: SyncEntryRecord[][] = []
  const store = makeSandboxRecordStore(services.db, {
    serverId: "server-mac",
    now: () => Date.parse("2026-10-29T00:00:00.000Z"),
    changed: (entries) => changes.push([...entries])
  })
  return { db: services.db, store, changes }
}

describe("sandbox records", () => {
  it("moves this Mac's records into the synced namespace once, marked as made here", async () => {
    const { db, store, changes } = await storeOn([
      record("old-1"),
      record("old-2", { state: "archived" })
    ])

    const listed = await store.list()

    expect(listed.map((machine) => [machine.id, machine.createdOn])).toEqual([
      ["old-1", "server-mac"],
      ["old-2", "server-mac"]
    ])
    expect(changes.flat().map((entry) => entry.key)).toEqual(["old-1", "old-2"])
    expect(await run(db.getMachineSetting("ephemeral-machines"))).toBeUndefined()
    expect((await run(db.getSyncEntries(SANDBOX_RECORDS_NAMESPACE))).length).toBe(2)
  })

  it("keeps a record that already synced in over the old copy", async () => {
    const { services } = await makeServices("server-mac")
    await run(
      services.db.mergeSyncEntries(SANDBOX_RECORDS_NAMESPACE, [
        {
          key: "shared",
          value: record("shared", { state: "failed", createdOn: "server-studio" }),
          timestamp: { wallMs: 1, counter: 0, deviceId: "server-studio" }
        }
      ])
    )
    await run(
      services.db.setMachineSetting("ephemeral-machines", JSON.stringify([record("shared")]))
    )

    const store = makeSandboxRecordStore(services.db, { serverId: "server-mac" })

    expect(await store.list()).toMatchObject([
      { id: "shared", state: "failed", createdOn: "server-studio" }
    ])
    expect(await run(services.db.getMachineSetting("ephemeral-machines"))).toBeUndefined()
  })

  it("syncs each write, leaves a tombstone on removal and takes records from other machines", async () => {
    const { store, changes } = await storeOn()

    await store.put(record("b", { createdAt: "2026-10-24T00:00:00.000Z" }))
    await store.put(record("a", { createdAt: "2026-10-24T00:00:00.000Z" }))
    await store.remove("b")
    await store.merge([
      {
        key: "elsewhere",
        value: record("elsewhere", { createdOn: "server-studio" }),
        timestamp: { wallMs: 9, counter: 0, deviceId: "server-studio" }
      }
    ])
    await store.merge([])

    expect((await store.list()).map((machine) => machine.id)).toEqual(["elsewhere", "a"])
    expect(await store.get("b")).toBeUndefined()
    expect(await store.entry("b")).toMatchObject({ key: "b", deleted: true })
    await expect(store.entry("never")).rejects.toThrow("No sandbox never")
    expect(changes.map((batch) => batch.map((entry) => entry.key))).toEqual([
      ["b"],
      ["a"],
      ["b"],
      ["elsewhere"]
    ])
  })
})

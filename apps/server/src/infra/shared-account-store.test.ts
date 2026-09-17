import { describe, expect, it, vi } from "vitest"

import { makeServices, run } from "../test-support.js"
import {
  makeSharedAccountStore,
  sharedAccountValue,
  SHARED_ACCOUNTS_NAMESPACE
} from "./shared-account-store.js"
const row = {
  id: "shared-account",
  harnessId: "codex" as const,
  label: "Work",
  createdAt: 1,
  credential: { id: "credential-id-0001", key: "a".repeat(43) }
}
describe("shared account metadata", () => {
  it("rejects malformed records and credentials without blocking the rest of a sync document", async () => {
    for (const value of [
      null,
      "x",
      {},
      { ...row, id: "../bad" },
      { ...row, harnessId: "other" },
      { ...row, label: 3 },
      { ...row, createdAt: NaN },
      ...[
        null,
        {},
        { id: "x", key: "x" },
        { id: row.credential.id, key: 1 },
        { id: row.credential.id, key: "x" }
      ].map((credential) => ({ ...row, credential })),
      { ...row, subject: 5 }
    ])
      expect(sharedAccountValue(value)).toBeUndefined()
    expect(sharedAccountValue(row)).toEqual(row)
    const { services } = await makeServices()
    const store = makeSharedAccountStore(services.db, "test")
    await run(
      services.db.mergeSyncEntries(SHARED_ACCOUNTS_NAMESPACE, [
        { key: "shared-invalid", value: null, timestamp: { wallMs: 1, counter: 0, deviceId: "a" } },
        { key: "shared-mismatch", value: row, timestamp: { wallMs: 1, counter: 1, deviceId: "a" } }
      ])
    )
    expect(await store.accounts()).toEqual([])
  })
  it("publishes real changes, preserves the shared default and clears stale overrides", async () => {
    const { services } = await makeServices()
    const store = makeSharedAccountStore(services.db, "test")
    const changed = vi.fn(),
      unsubscribe = store.subscribe(changed)
    await store.save(row)
    await store.save(row)
    expect(changed).toHaveBeenCalledTimes(1)
    await store.save({ ...row, id: "shared-other", createdAt: 1 })
    await store.select("codex", row.id, false)
    await store.select("codex", "shared-other", true)
    expect(await store.overridden("codex")).toBe(true)
    expect(await store.selected("codex", true)).toBe("shared-other")
    expect(await store.selected("codex", false)).toBe(row.id)
    await store.remove("shared-other")
    expect(await store.overridden("codex")).toBe(false)
    expect(await store.selected("codex", true)).toBe(row.id)
    await store.inherit("codex")
    expect(await store.selected("claude-code", true)).toBeUndefined()
    unsubscribe()
    const calls = changed.mock.calls.length
    await store.remove(row.id)
    expect(changed).toHaveBeenCalledTimes(calls)
    expect(await store.selected("codex", true)).toBeUndefined()
  })
})

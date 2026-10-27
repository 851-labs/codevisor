import { expect, it } from "vitest"

import { makeServices, run } from "../../test-support.js"
import {
  makePluginAccountStore,
  PLUGIN_ACCOUNTS_NAMESPACE,
  type PluginAccountRecord
} from "./plugin-account-store.js"

const record = (
  id: string,
  createdAt: string,
  overrides: Partial<PluginAccountRecord> = {}
): PluginAccountRecord => ({
  id,
  plugin: "dev.codevisor/grafana",
  label: id,
  method: "fields",
  values: { url: "https://grafana.example.com" },
  secretsSet: ["token"],
  status: "ok",
  createdAt,
  credential: { id: "credential-0123456789", key: "k".repeat(43) },
  ...overrides
})

it("lists a plugin's accounts oldest first, skipping removed and unreadable synced entries", async () => {
  const { services } = await makeServices("server-a")
  const store = makePluginAccountStore(services.db, "server-a", () => Date.UTC(2026, 9, 27, 9))
  await store.save(record("newer", "2026-10-27T10:00:00.000Z"))
  await store.save(record("older", "2026-10-27T09:00:00.000Z"))
  await store.save(record("removed", "2026-10-27T08:00:00.000Z"))
  await store.save(
    record("other-plugin", "2026-10-27T08:00:00.000Z", { plugin: "dev.codevisor/gmail" })
  )
  await store.remove("removed")
  await run(
    services.db.mergeSyncEntries(PLUGIN_ACCOUNTS_NAMESPACE, [
      {
        key: "garbled",
        value: { id: "garbled" },
        timestamp: { wallMs: 1, counter: 0, deviceId: "mac-b" }
      },
      {
        key: "renamed",
        value: record("not-renamed", "2026-10-27T07:00:00.000Z"),
        timestamp: { wallMs: 1, counter: 0, deviceId: "mac-b" }
      },
      {
        key: "bad-credential",
        value: record("bad-credential", "2026-10-27T07:00:00.000Z", {
          credential: { id: "short", key: "short" }
        }),
        timestamp: { wallMs: 1, counter: 0, deviceId: "mac-b" }
      }
    ])
  )

  const listed = await store.list("dev.codevisor/grafana")

  expect(listed.map((account) => account.id)).toEqual(["older", "newer"])
  expect(await store.get("older")).toEqual(record("older", "2026-10-27T09:00:00.000Z"))
  expect(await store.get("removed")).toBeUndefined()
})

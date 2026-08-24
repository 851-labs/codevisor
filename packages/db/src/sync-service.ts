import { mergeSyncEntries, type SyncEntryRecord } from "@codevisor/sync"
import { attempt } from "./errors.js"
import type { CodevisorDatabaseService } from "./service.js"
import type { ServiceContext } from "./service-context.js"

interface SyncRow {
  readonly namespace: string
  readonly key: string
  readonly value: string
  readonly deleted: number
  readonly ts_wall: number
  readonly ts_counter: number
  readonly ts_device: string
}

const recordFromRow = (row: SyncRow): SyncEntryRecord => ({
  key: row.key,
  value: JSON.parse(row.value) as unknown,
  ...(row.deleted === 1 ? { deleted: true } : {}),
  timestamp: { wallMs: row.ts_wall, counter: row.ts_counter, deviceId: row.ts_device }
})

/// The server's replica of the config plane: per-namespace LWW documents
/// (see @codevisor/sync). Merge semantics live in the pure package; this
/// service persists the outcome.
export const makeSyncService = (
  context: ServiceContext
): Pick<CodevisorDatabaseService, "getSyncEntries" | "mergeSyncEntries"> => {
  const { sqlite } = context

  const load = (namespace: string): ReadonlyArray<SyncEntryRecord> =>
    (
      sqlite
        .prepare("select * from sync_entries where namespace = ? order by key")
        .all(namespace) as Array<SyncRow>
    ).map(recordFromRow)

  return {
    getSyncEntries: (namespace) => attempt("getSyncEntries", () => load(namespace)),
    mergeSyncEntries: (namespace, entries) =>
      attempt("mergeSyncEntries", () => {
        const result = mergeSyncEntries(load(namespace), entries)
        const upsert = sqlite.prepare(
          `insert into sync_entries (
            namespace, key, value, deleted, ts_wall, ts_counter, ts_device
          ) values (?, ?, ?, ?, ?, ?, ?)
          on conflict(namespace, key) do update set
            value = excluded.value,
            deleted = excluded.deleted,
            ts_wall = excluded.ts_wall,
            ts_counter = excluded.ts_counter,
            ts_device = excluded.ts_device`
        )
        for (const entry of result.changed) {
          upsert.run(
            namespace,
            entry.key,
            JSON.stringify(entry.value ?? null),
            entry.deleted === true ? 1 : 0,
            entry.timestamp.wallMs,
            entry.timestamp.counter,
            entry.timestamp.deviceId
          )
        }
        return result
      })
  }
}

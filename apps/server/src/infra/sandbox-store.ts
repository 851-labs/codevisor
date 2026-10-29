import { Sandbox } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { latestSyncTimestamp, nextSyncTimestamp, type SyncEntryRecord } from "@codevisor/sync"
import { Option, Schema } from "effect"

import { HttpFailure, run } from "../server-context.js"

export interface SandboxRecordStore {
  readonly list: () => Promise<ReadonlyArray<Sandbox>>
  readonly get: (id: string) => Promise<Sandbox | undefined>
  readonly put: (machine: Sandbox) => Promise<void>
  readonly remove: (id: string) => Promise<void>
  readonly entry: (id: string) => Promise<SyncEntryRecord>
  readonly merge: (entries: ReadonlyArray<SyncEntryRecord>) => Promise<void>
}

export interface SandboxRecordStoreOptions {
  readonly serverId: string
  readonly now?: () => number
  readonly changed?: (entries: ReadonlyArray<SyncEntryRecord>) => void
}

type RecordsDatabase = Pick<
  CodevisorDatabaseService,
  "getSyncEntries" | "mergeSyncEntries" | "getMachineSetting" | "setMachineSetting"
>

export const SANDBOX_RECORDS_NAMESPACE = "sandbox-records"

const legacyRecordsKey = "ephemeral-machines"
const decodeLegacyRecords = Schema.decodeUnknownSync(Schema.fromJsonString(Schema.Array(Sandbox)))
const decodeRecord = Schema.decodeUnknownOption(Sandbox)

export const makeSandboxRecordStore = (
  db: RecordsDatabase,
  options: SandboxRecordStoreOptions
): SandboxRecordStore => {
  const now = options.now ?? Date.now
  const entries = () => run(db.getSyncEntries(SANDBOX_RECORDS_NAMESPACE))
  const merge = async (incoming: ReadonlyArray<SyncEntryRecord>): Promise<void> => {
    const result = await run(db.mergeSyncEntries(SANDBOX_RECORDS_NAMESPACE, incoming))
    if (result.changed.length > 0) options.changed?.(result.changed)
  }
  const migrated = migrateLegacyRecords(db, options.serverId, now, entries, merge)
  let writes = migrated
  const serialized = (work: () => Promise<void>): Promise<void> => {
    writes = writes.then(work)
    return writes
  }
  const write = (key: string, value: Sandbox | null) =>
    serialized(async () => {
      const timestamp = nextSyncTimestamp(
        options.serverId,
        latestSyncTimestamp(await entries()),
        now()
      )
      await merge([
        value === null ? { key, value, deleted: true, timestamp } : { key, value, timestamp }
      ])
    })
  const live = async (): Promise<ReadonlyArray<SyncEntryRecord>> => {
    await migrated
    return (await entries()).filter((entry) => entry.deleted !== true)
  }
  const list = async (): Promise<ReadonlyArray<Sandbox>> =>
    (await live())
      .flatMap((entry) => Option.toArray(decodeRecord(entry.value)))
      .toSorted(byCreation)
  return {
    list,
    get: async (id) => (await list()).find((machine) => machine.id === id),
    put: (machine) => write(machine.id, machine),
    remove: (id) => write(id, null),
    entry: async (id) => {
      await migrated
      const found = (await entries()).find((entry) => entry.key === id)
      if (found === undefined) throw new HttpFailure(404, `No sandbox ${id}`)
      return found
    },
    merge: (incoming) => serialized(() => merge(incoming))
  }
}

const migrateLegacyRecords = async (
  db: RecordsDatabase,
  serverId: string,
  now: () => number,
  entries: () => Promise<ReadonlyArray<SyncEntryRecord>>,
  merge: (incoming: ReadonlyArray<SyncEntryRecord>) => Promise<void>
): Promise<void> => {
  const stored = await run(db.getMachineSetting(legacyRecordsKey))
  if (stored === undefined) return

  const existing = await entries()
  const synced = new Set(existing.map((entry) => entry.key))
  let latest = latestSyncTimestamp(existing)
  const migrated = decodeLegacyRecords(stored)
    .filter((record) => !synced.has(record.id))
    .map((record): SyncEntryRecord => {
      latest = nextSyncTimestamp(serverId, latest, now())
      return { key: record.id, value: { ...record, createdOn: serverId }, timestamp: latest }
    })
  if (migrated.length > 0) await merge(migrated)
  await run(db.setMachineSetting(legacyRecordsKey, undefined))
}

const byCreation = (a: Sandbox, b: Sandbox): number =>
  a.createdAt.localeCompare(b.createdAt) || a.id.localeCompare(b.id)

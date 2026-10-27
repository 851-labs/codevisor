import { PluginAccountMethod, PluginAccountStatus, type PluginAccount } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { latestSyncTimestamp, nextSyncTimestamp, type SyncEntryRecord } from "@codevisor/sync"
import { Effect, Schema } from "effect"

export const PLUGIN_ACCOUNTS_NAMESPACE = "plugin-accounts"

export interface CredentialReference {
  readonly id: string
  readonly key: string
}

export interface PluginAccountRecord extends PluginAccount {
  readonly credential?: CredentialReference
}

export interface PluginAccountStore {
  readonly list: (plugin: string) => Promise<ReadonlyArray<PluginAccountRecord>>
  readonly get: (id: string) => Promise<PluginAccountRecord | undefined>
  readonly save: (record: PluginAccountRecord) => Promise<ReadonlyArray<SyncEntryRecord>>
  readonly remove: (id: string) => Promise<ReadonlyArray<SyncEntryRecord>>
}

export const makePluginAccountStore = (
  db: CodevisorDatabaseService,
  serverId: string,
  now: () => number = Date.now
): PluginAccountStore => {
  const entries = () => Effect.runPromise(db.getSyncEntries(PLUGIN_ACCOUNTS_NAMESPACE))

  const records = async (): Promise<ReadonlyArray<PluginAccountRecord>> =>
    (await entries()).flatMap(liveRecord)

  const write = async (
    key: string,
    value: unknown,
    deleted: boolean
  ): Promise<ReadonlyArray<SyncEntryRecord>> => {
    const previous = await entries()
    const timestamp = nextSyncTimestamp(serverId, latestSyncTimestamp(previous), now())
    const result = await Effect.runPromise(
      db.mergeSyncEntries(PLUGIN_ACCOUNTS_NAMESPACE, [{ key, value, deleted, timestamp }])
    )
    return result.changed
  }

  return {
    list: async (plugin) =>
      (await records())
        .filter((record) => record.plugin === plugin)
        .toSorted((left, right) => left.createdAt.localeCompare(right.createdAt)),
    get: async (id) => (await records()).find((record) => record.id === id),
    save: (record) => write(record.id, record, false),
    remove: (id) => write(id, null, true)
  }
}

export const publicAccount = (record: PluginAccountRecord): PluginAccount => {
  const { credential: _credential, ...visible } = record
  return visible
}

const CredentialSchema = Schema.Struct({
  id: Schema.String.check(Schema.isPattern(/^[a-zA-Z0-9_-]{16,100}$/)),
  key: Schema.String.check(Schema.isPattern(/^[a-zA-Z0-9_-]{43}$/))
})

const RecordSchema = Schema.Struct({
  id: Schema.String,
  plugin: Schema.String,
  label: Schema.optional(Schema.String),
  identity: Schema.optional(Schema.String),
  method: PluginAccountMethod,
  values: Schema.Record(
    Schema.String,
    Schema.Union([Schema.String, Schema.Number, Schema.Boolean])
  ),
  secretsSet: Schema.Array(Schema.String),
  scopes: Schema.optional(Schema.Array(Schema.String)),
  status: PluginAccountStatus,
  createdAt: Schema.String,
  credential: Schema.optional(CredentialSchema)
})

const liveRecord = (entry: SyncEntryRecord): ReadonlyArray<PluginAccountRecord> => {
  if (entry.deleted === true) return []
  const decoded = Schema.decodeUnknownOption(RecordSchema)(entry.value)
  if (decoded._tag === "None" || decoded.value.id !== entry.key) return []
  const { credential, ...rest } = decoded.value
  return [{ ...rest, ...(credential === undefined ? {} : { credential }) }]
}

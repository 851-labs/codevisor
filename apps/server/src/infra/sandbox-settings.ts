import { SandboxFieldValues, SandboxProfile, SandboxProviderKind } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { latestSyncTimestamp, nextSyncTimestamp, type SyncEntryRecord } from "@codevisor/sync"
import { Option, Schema } from "effect"

import { run } from "../server-context.js"

export const SANDBOX_ACCOUNTS_NAMESPACE = "sandbox-accounts"
export const SANDBOX_PROFILES_NAMESPACE = "sandbox-profiles"

export const StoredSandboxAccount = Schema.Struct({
  id: Schema.String,
  provider: SandboxProviderKind,
  label: Schema.optional(Schema.String),
  identity: Schema.optional(Schema.String),
  values: SandboxFieldValues,
  createdAt: Schema.String
})
export type StoredSandboxAccount = typeof StoredSandboxAccount.Type

export interface SandboxSettingsChange {
  readonly namespace: string
  readonly entries: ReadonlyArray<SyncEntryRecord>
}

export interface SandboxSettings {
  readonly accounts: () => Promise<ReadonlyArray<StoredSandboxAccount>>
  readonly account: (id: string) => Promise<StoredSandboxAccount | undefined>
  readonly putAccount: (account: StoredSandboxAccount) => Promise<SandboxSettingsChange>
  readonly removeAccount: (id: string) => Promise<SandboxSettingsChange>
  readonly profiles: () => Promise<ReadonlyArray<SandboxProfile>>
  readonly profile: (id: string) => Promise<SandboxProfile | undefined>
  readonly putProfile: (profile: SandboxProfile) => Promise<SandboxSettingsChange>
  readonly removeProfile: (id: string) => Promise<SandboxSettingsChange>
}

type SyncDatabase = Pick<CodevisorDatabaseService, "getSyncEntries" | "mergeSyncEntries">

export const makeSandboxSettings = (
  db: SyncDatabase,
  serverId: string,
  now: () => number = Date.now
): SandboxSettings => {
  const accounts = syncedCollection(db, serverId, now, SANDBOX_ACCOUNTS_NAMESPACE, decodeAccount)
  const profiles = syncedCollection(db, serverId, now, SANDBOX_PROFILES_NAMESPACE, decodeProfile)
  return {
    accounts: accounts.list,
    account: accounts.get,
    putAccount: accounts.put,
    removeAccount: accounts.remove,
    profiles: profiles.list,
    profile: profiles.get,
    putProfile: profiles.put,
    removeProfile: profiles.remove
  }
}

const decodeAccount = Schema.decodeUnknownOption(StoredSandboxAccount)
const decodeProfile = Schema.decodeUnknownOption(SandboxProfile)

interface Identified {
  readonly id: string
  readonly createdAt: string
}

const byCreation = (a: Identified, b: Identified): number =>
  a.createdAt.localeCompare(b.createdAt) || a.id.localeCompare(b.id)

const syncedCollection = <T extends Identified>(
  db: SyncDatabase,
  serverId: string,
  now: () => number,
  namespace: string,
  decode: (value: unknown) => Option.Option<T>
) => {
  const list = async (): Promise<ReadonlyArray<T>> =>
    (await run(db.getSyncEntries(namespace)))
      .filter((entry) => entry.deleted !== true)
      .flatMap((entry) => Option.toArray(decode(entry.value)))
      .toSorted(byCreation)
  const write = async (key: string, value: T | null): Promise<SandboxSettingsChange> => {
    const timestamp = nextSyncTimestamp(
      serverId,
      latestSyncTimestamp(await run(db.getSyncEntries(namespace))),
      now()
    )
    const entry =
      value === null ? { key, value, deleted: true, timestamp } : { key, value, timestamp }
    const result = await run(db.mergeSyncEntries(namespace, [entry]))
    return { namespace, entries: result.changed }
  }
  return {
    list,
    get: async (id: string): Promise<T | undefined> =>
      (await list()).find((item) => item.id === id),
    put: (item: T) => write(item.id, item),
    remove: (id: string) => write(id, null)
  }
}

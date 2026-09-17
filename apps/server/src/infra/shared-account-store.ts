import type { CodevisorDatabaseService } from "@codevisor/db"
import type { SharedCredentialReference, SharedOAuthHarness } from "@codevisor/harness-manager"
import { latestSyncTimestamp, nextSyncTimestamp, type SyncEntryRecord } from "@codevisor/sync"
import { Effect } from "effect"

export const SHARED_ACCOUNTS_NAMESPACE = "harness-shared-accounts"
export const SHARED_ACCOUNT_OVERRIDES = "local.harness-account-overrides"

export interface SharedHarnessAccount {
  readonly id: string
  readonly harnessId: SharedOAuthHarness
  readonly label: string
  readonly subject?: string
  readonly email?: string
  readonly organizationId?: string
  readonly createdAt: number
  readonly credential?: SharedCredentialReference
  readonly sourceMachineId?: string
  readonly sourceExpiresAt?: number
}

export const sharedHarness = (id: string): id is SharedOAuthHarness =>
  id === "claude-code" || id === "codex"
export const sharedAccountValue = (value: unknown): SharedHarnessAccount | undefined => {
  if (value === null || typeof value !== "object") return undefined
  const row = value as SharedHarnessAccount
  if (
    typeof row.id !== "string" ||
    !/^shared-[a-zA-Z0-9-]+$/.test(row.id) ||
    !sharedHarness(row.harnessId) ||
    typeof row.label !== "string" ||
    !Number.isFinite(row.createdAt)
  )
    return undefined
  if (
    row.credential !== undefined &&
    (typeof row.credential?.id !== "string" ||
      !/^[a-zA-Z0-9_-]{16,100}$/.test(row.credential.id) ||
      typeof row.credential.key !== "string" ||
      !/^[a-zA-Z0-9_-]{43}$/.test(row.credential.key))
  )
    return undefined
  if (
    [row.subject, row.email, row.organizationId, row.sourceMachineId].some(
      (field) => field !== undefined && typeof field !== "string"
    )
  )
    return undefined
  return row
}

export const makeSharedAccountStore = (db: CodevisorDatabaseService, serverId: string) => {
  const listeners = new Set<(entries: ReadonlyArray<SyncEntryRecord>) => void>()
  const entries = () => Effect.runPromise(db.getSyncEntries(SHARED_ACCOUNTS_NAMESPACE))
  const write = async (namespace: string, key: string, value: unknown, deleted = false) => {
    const previous = await Effect.runPromise(db.getSyncEntries(namespace))
    const current = previous.find((entry) => entry.key === key)
    if (
      current &&
      (current.deleted === true) === deleted &&
      JSON.stringify(current.value) === JSON.stringify(value)
    )
      return
    const entry = {
      key,
      value,
      deleted,
      timestamp: nextSyncTimestamp(serverId, latestSyncTimestamp(previous), Date.now())
    }
    await Effect.runPromise(db.mergeSyncEntries(namespace, [entry]))
    if (namespace === SHARED_ACCOUNTS_NAMESPACE) for (const listener of listeners) listener([entry])
  }
  const accounts = async (): Promise<SharedHarnessAccount[]> =>
    (await entries()).flatMap((entry) => {
      if (entry.deleted === true || !entry.key.startsWith("shared-")) return []
      const value = sharedAccountValue(entry.value)
      return value && value.id === entry.key ? [value] : []
    })
  return {
    accounts,
    entries,
    writeProvider: (key: string, value: unknown, deleted = false) =>
      write(SHARED_ACCOUNTS_NAMESPACE, key, value, deleted),
    overridden: async (harnessId: string) => {
      const available = await accounts()
      return (await Effect.runPromise(db.getSyncEntries(SHARED_ACCOUNT_OVERRIDES))).some(
        (entry) =>
          entry.key === harnessId &&
          entry.deleted !== true &&
          available.some((account) => account.id === entry.value && account.credential)
      )
    },
    get: async (id: string) => (await accounts()).find((account) => account.id === id),
    save: (account: SharedHarnessAccount) => write(SHARED_ACCOUNTS_NAMESPACE, account.id, account),
    remove: (id: string) => write(SHARED_ACCOUNTS_NAMESPACE, id, null, true),
    selected: async (harnessId: string, machine: boolean): Promise<string | undefined> => {
      const available = (await accounts())
        .filter((account) => account.harnessId === harnessId && account.credential !== undefined)
        .sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id))
      if (machine) {
        const overrides = await Effect.runPromise(db.getSyncEntries(SHARED_ACCOUNT_OVERRIDES))
        const override = overrides.find((entry) => entry.key === harnessId)
        if (
          override?.deleted !== true &&
          typeof override?.value === "string" &&
          available.some((account) => account.id === override.value)
        )
          return override.value
      }
      const selected = (await entries()).find((entry) => entry.key === `selected:${harnessId}`)
      const value = selected?.value as { id?: string; automatic?: boolean } | undefined
      if (
        selected?.deleted !== true &&
        value?.automatic !== true &&
        available.some((account) => account.id === value?.id)
      )
        return value?.id
      return available[0]?.id
    },
    select: (harnessId: string, id: string, machine: boolean) =>
      write(
        machine ? SHARED_ACCOUNT_OVERRIDES : SHARED_ACCOUNTS_NAMESPACE,
        machine ? harnessId : `selected:${harnessId}`,
        machine ? id : { id, automatic: false }
      ),
    inherit: (harnessId: string) => write(SHARED_ACCOUNT_OVERRIDES, harnessId, null, true),
    subscribe: (listener: (entries: ReadonlyArray<SyncEntryRecord>) => void) => {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    }
  }
}

export type SharedAccountStore = ReturnType<typeof makeSharedAccountStore>

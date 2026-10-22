import type { CodevisorDatabaseService } from "@codevisor/db"
import { latestSyncTimestamp, nextSyncTimestamp, type SyncEntryRecord } from "@codevisor/sync"
import { Effect } from "effect"

export const ACCOUNTS_SYNC_NAMESPACE = "harness-accounts"

export interface AccountsRosterDeps {
  readonly db: CodevisorDatabaseService
  readonly harnessIds: ReadonlyArray<string>
  readonly serverId: string
  readonly now?: () => number
}

export const HARNESS_READINESS_NAMESPACE = "harness-readiness"

export interface HarnessReadinessRow {
  readonly id: string
  readonly name: string
  readonly symbolName: string
  readonly installed?: boolean
  readonly authRequired: boolean
  readonly state:
    | "ready"
    | "signInRequired"
    | "notInstalled"
    | "disabled"
    | "blocked"
    | "installing"
    | "uninstalling"
  readonly reason?: string | undefined
  readonly version?: string
}

export const publishMachineReadiness = async (deps: {
  readonly db: CodevisorDatabaseService
  readonly namespace: string
  readonly serverId: string
  readonly value: object
  readonly now?: () => number
  readonly answers?: ReadonlyArray<SyncEntryRecord>
}): Promise<{ readonly changedEntries: ReadonlyArray<SyncEntryRecord> }> => {
  const now = deps.now ?? Date.now
  const answers = deps.answers ?? []
  const replica = await run(deps.db.getSyncEntries(deps.namespace))
  const existing = replica.find((entry) => entry.key === deps.serverId)
  if (
    answers.length === 0 &&
    existing !== undefined &&
    JSON.stringify(existing.value) === JSON.stringify(deps.value)
  ) {
    return { changedEntries: [] }
  }
  const timestamp = nextSyncTimestamp(
    deps.serverId,
    latestSyncTimestamp([...replica, ...answers]),
    now()
  )
  const result = await run(
    deps.db.mergeSyncEntries(deps.namespace, [{ key: deps.serverId, value: deps.value, timestamp }])
  )
  return { changedEntries: result.changed }
}

export const PLUGIN_READINESS_NAMESPACE = "plugin-readiness"

export interface PluginReadinessRow {
  readonly id: string
  readonly state: "ready" | "disabled" | "notInstalled" | "blocked" | "machineOnly"
  readonly reason?: string | undefined
}

export const publishAccountsRoster = async (
  deps: AccountsRosterDeps
): Promise<{ readonly changedEntries: ReadonlyArray<SyncEntryRecord> }> => {
  const now = deps.now ?? Date.now
  const accounts: Array<{
    readonly harnessId: string
    readonly label: string
    readonly email?: string | undefined
    readonly authState: string
    readonly profileKind: string
  }> = []
  for (const harnessId of deps.harnessIds) {
    for (const account of await run(deps.db.listHarnessAccounts(harnessId))) {
      accounts.push({
        harnessId,
        label: account.label,
        ...(account.email === undefined ? {} : { email: account.email }),
        authState: account.authState,
        profileKind: account.profileKind
      })
    }
  }
  const replica = await run(deps.db.getSyncEntries(ACCOUNTS_SYNC_NAMESPACE))
  const existing = replica.find((entry) => entry.key === deps.serverId)
  const value = { accounts }
  if (existing !== undefined && JSON.stringify(existing.value) === JSON.stringify(value)) {
    return { changedEntries: [] }
  }
  const timestamp = nextSyncTimestamp(deps.serverId, latestSyncTimestamp(replica), now())
  const result = await run(
    deps.db.mergeSyncEntries(ACCOUNTS_SYNC_NAMESPACE, [{ key: deps.serverId, value, timestamp }])
  )
  return { changedEntries: result.changed }
}

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

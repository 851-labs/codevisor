import type { HarnessPreference } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { SyncEntryRecord } from "@codevisor/sync"
import { Effect } from "effect"

import {
  effectiveHarnessPreference,
  HARNESSES_SYNC_NAMESPACE,
  readHarnessSettings
} from "./harness-preferences.js"
import { flushPending, openSyncStamps } from "./sync-ledger.js"

export { HARNESSES_SYNC_NAMESPACE }

export interface LocalHarnessState {
  readonly id: string
  readonly enabled: boolean
  readonly installed: boolean
  readonly authenticated: boolean
  readonly phase?: string | undefined
  readonly name?: string | undefined
  readonly symbolName?: string | undefined
}

export interface HarnessSyncDeps {
  readonly db: CodevisorDatabaseService
  readonly serverId: string
  readonly now?: () => number
  readonly listHarnesses: () => Promise<ReadonlyArray<LocalHarnessState>>
  readonly setEnabled: (harnessId: string, enabled: boolean) => Promise<void>
  readonly beginInstall: (harnessId: string) => Promise<void>
  readonly beginUninstall?: (harnessId: string) => Promise<void>
}

export interface HarnessSyncStatus {
  readonly published: ReadonlyArray<string>
  readonly applied: ReadonlyArray<string>
  readonly removed: ReadonlyArray<string>
  readonly installing: ReadonlyArray<string>
  readonly blocked: ReadonlyArray<{ readonly id: string; readonly reason: string }>
}

export interface HarnessSyncResult {
  readonly status: HarnessSyncStatus
  readonly changedEntries: ReadonlyArray<SyncEntryRecord>
}

export const reconcileHarnesses = async (deps: HarnessSyncDeps): Promise<HarnessSyncResult> => {
  const now = deps.now ?? Date.now
  const locals = await deps.listHarnesses()
  const localById = new Map(locals.map((harness) => [harness.id, harness]))
  const replica = await run(deps.db.getSyncEntries(HARNESSES_SYNC_NAMESPACE))
  const sync = openHarnessSync()
  const promotions = promotedHarnesses(deps, now, replica, locals, sync)

  const promoted = flushPending(deps, HARNESSES_SYNC_NAMESPACE, promotions)
  if (promoted !== undefined) sync.changedEntries = (await promoted).changed
  const preferences = await readHarnessSettings(deps.db)

  for (const [id, settings] of preferences) {
    const local = localById.get(id)
    if (local === undefined) continue

    const wanted = effectiveHarnessPreference(settings)
    if (changesEnabled(local, wanted)) {
      await deps.setEnabled(id, wanted.enabled)
      sync.applied.push(id)
    }

    const transition = harnessTransition(local, wanted)
    if (transition === "install") {
      try {
        await deps.beginInstall(id)
        sync.installing.push(id)
      } catch (cause) {
        recordBlockage(sync, id, cause)
      }
    } else if (transition === "uninstall") {
      try {
        await startUninstall(deps, id)
        sync.applied.push(id)
      } catch (cause) {
        recordBlockage(sync, id, cause)
      }
    } else if (transition === "signIn") {
      sync.blocked.push({ id, reason: "Sign in required" })
    }
  }

  return { status: harnessStatus(sync), changedEntries: sync.changedEntries }
}

interface HarnessSync {
  readonly published: Array<string>
  readonly applied: Array<string>
  readonly installing: Array<string>
  readonly blocked: Array<HarnessBlockage>
  changedEntries: ReadonlyArray<SyncEntryRecord>
}

interface HarnessBlockage {
  readonly id: string
  readonly reason: string
}

type HarnessTransition = "busy" | "install" | "uninstall" | "signIn" | "none"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const openHarnessSync = (): HarnessSync => ({
  published: [],
  applied: [],
  installing: [],
  blocked: [],
  changedEntries: []
})

const promotedHarnesses = (
  deps: HarnessSyncDeps,
  now: () => number,
  replica: ReadonlyArray<SyncEntryRecord>,
  locals: ReadonlyArray<LocalHarnessState>,
  sync: HarnessSync
): Array<SyncEntryRecord> => {
  const stamps = openSyncStamps(deps, replica, now)
  const authored = new Set(replica.map((entry) => entry.key))
  const promotions: Array<SyncEntryRecord> = []
  for (const local of locals) {
    if (!promotable(authored, local)) continue

    promotions.push(stamps.entry(local.id, promotedValue(local)))
    sync.published.push(local.id)
  }
  return promotions
}

const startUninstall = (deps: HarnessSyncDeps, id: string): Promise<void> => {
  if (deps.beginUninstall === undefined) throw new Error("Uninstall unavailable on this machine")
  return deps.beginUninstall(id)
}

const recordBlockage = (sync: HarnessSync, id: string, cause: unknown): void => {
  sync.blocked.push(blockage(id, cause))
}

const harnessTransition = (
  local: LocalHarnessState,
  wanted: HarnessPreference
): HarnessTransition => {
  if (isBusy(local)) return "busy"
  if (wanted.installed === true && !local.installed) return "install"
  if (wanted.installed === false && local.installed) return "uninstall"
  if (wanted.enabled && local.installed && !local.authenticated) return "signIn"
  return "none"
}

const changesEnabled = (
  local: LocalHarnessState,
  wanted: HarnessPreference
): wanted is HarnessPreference & { readonly enabled: boolean } =>
  wanted.enabled !== undefined && wanted.enabled !== local.enabled

const isBusy = (local: LocalHarnessState): boolean =>
  local.phase === "installing" || local.phase === "updating" || local.phase === "uninstalling"

const promotable = (authored: ReadonlySet<string>, local: LocalHarnessState): boolean =>
  !authored.has(local.id) && local.installed && local.enabled && local.authenticated

const promotedValue = (local: LocalHarnessState): object => ({
  ...(local.name === undefined ? {} : { name: local.name }),
  ...(local.symbolName === undefined ? {} : { symbolName: local.symbolName }),
  enabled: true,
  installed: true,
  uninstall: false
})

const harnessStatus = (sync: HarnessSync): HarnessSyncStatus => ({
  published: sync.published,
  applied: sync.applied,
  removed: [],
  installing: sync.installing,
  blocked: sync.blocked
})

const blockage = (id: string, cause: unknown): HarnessBlockage => ({
  id,
  reason: cause instanceof Error ? cause.message : String(cause)
})

import type { CodevisorDatabaseService } from "@codevisor/db"
import {
  latestSyncTimestamp,
  nextSyncTimestamp,
  type SyncEntryRecord,
  type SyncTimestampValue
} from "@codevisor/sync"
import { Effect } from "effect"

import {
  effectiveHarnessPreference,
  HARNESSES_SYNC_NAMESPACE,
  readHarnessSettings
} from "./harness-preferences.js"

export { HARNESSES_SYNC_NAMESPACE }

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

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

  const published: Array<string> = []
  const applied: Array<string> = []
  const installing: Array<string> = []
  const blocked: Array<{ id: string; reason: string }> = []
  let clock: SyncTimestampValue | undefined = latestSyncTimestamp(replica)
  const stamp = (): SyncTimestampValue => {
    clock = nextSyncTimestamp(deps.serverId, clock, now())
    return clock
  }
  const authored = new Set(replica.map((entry) => entry.key))
  const promotions: Array<SyncEntryRecord> = []
  for (const local of locals) {
    if (authored.has(local.id) || !local.installed || !local.enabled || !local.authenticated)
      continue
    promotions.push({
      key: local.id,
      value: {
        ...(local.name === undefined ? {} : { name: local.name }),
        ...(local.symbolName === undefined ? {} : { symbolName: local.symbolName }),
        enabled: true,
        installed: true,
        uninstall: false
      },
      timestamp: stamp()
    })
    published.push(local.id)
  }
  const changedEntries: ReadonlyArray<SyncEntryRecord> =
    promotions.length > 0
      ? (await run(deps.db.mergeSyncEntries(HARNESSES_SYNC_NAMESPACE, promotions))).changed
      : []
  const preferences = await readHarnessSettings(deps.db)
  for (const [id, settings] of preferences) {
    const local = localById.get(id)
    if (local === undefined) continue
    const wanted = effectiveHarnessPreference(settings)
    if (wanted.enabled !== undefined && wanted.enabled !== local.enabled) {
      await deps.setEnabled(id, wanted.enabled)
      applied.push(id)
    }
    if (
      local.phase === "installing" ||
      local.phase === "updating" ||
      local.phase === "uninstalling"
    )
      continue
    if (wanted.installed === true && !local.installed) {
      try {
        await deps.beginInstall(id)
        installing.push(id)
      } catch (cause) {
        blocked.push({ id, reason: cause instanceof Error ? cause.message : String(cause) })
      }
    } else if (wanted.installed === false && local.installed) {
      try {
        if (deps.beginUninstall === undefined)
          throw new Error("Uninstall unavailable on this machine")
        await deps.beginUninstall(id)
        applied.push(id)
      } catch (cause) {
        blocked.push({ id, reason: cause instanceof Error ? cause.message : String(cause) })
      }
    } else if (wanted.enabled && local.installed && !local.authenticated) {
      blocked.push({ id, reason: "Sign in required" })
    }
  }

  return {
    status: { published, applied, removed: [], installing, blocked },
    changedEntries
  }
}

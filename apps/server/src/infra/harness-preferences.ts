import type { Harness, HarnessPreference, HarnessSettings } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { latestSyncTimestamp, nextSyncTimestamp, type SyncEntryRecord } from "@codevisor/sync"
import { Effect } from "effect"

export const HARNESSES_SYNC_NAMESPACE = "harnesses"
const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

export const harnessPreference = (value: unknown): HarnessPreference | undefined => {
  if (typeof value !== "object" || value === null) return undefined
  const candidate = value as Record<string, unknown>
  if (typeof candidate.enabled !== "boolean" || typeof candidate.installed !== "boolean")
    return undefined
  if (!candidate.installed && candidate.uninstall !== true) return undefined
  return { enabled: candidate.enabled, installed: candidate.installed }
}

export const readHarnessSettings = async (
  db: CodevisorDatabaseService
): Promise<Map<string, HarnessSettings>> => {
  const result = new Map<string, HarnessSettings>()
  for (const entry of await run(db.getSyncEntries(HARNESSES_SYNC_NAMESPACE))) {
    if (entry.deleted) continue
    const preference = harnessPreference(entry.value)
    if (preference !== undefined) result.set(entry.key, { global: preference })
  }
  return result
}

export const effectiveHarnessPreference = (
  settings: HarnessSettings | undefined
): HarnessPreference => {
  const effective = settings?.global ?? {}
  return effective.installed === false ? { ...effective, enabled: false } : effective
}

export interface HarnessCatalogIdentity {
  readonly id: string
  readonly name: string
  readonly symbolName: string
}

export const setHarnessPreference = async (
  db: CodevisorDatabaseService,
  serverId: string,
  harness: HarnessCatalogIdentity,
  preference: { readonly enabled: boolean; readonly installed: boolean }
): Promise<ReadonlyArray<SyncEntryRecord>> => {
  const entries = await run(db.getSyncEntries(HARNESSES_SYNC_NAMESPACE))
  const previous = entries.find((entry) => entry.key === harness.id && !entry.deleted)
  const previousFields =
    typeof previous?.value === "object" && previous.value !== null
      ? (previous.value as Record<string, unknown>)
      : {}
  const result = await run(
    db.mergeSyncEntries(HARNESSES_SYNC_NAMESPACE, [
      {
        key: harness.id,
        value: {
          ...previousFields,
          name: harness.name,
          symbolName: harness.symbolName,
          enabled: preference.enabled,
          installed: preference.installed,
          uninstall: !preference.installed
        },
        timestamp: nextSyncTimestamp(serverId, latestSyncTimestamp(entries), Date.now())
      }
    ])
  )
  return result.changed
}

export const decorateHarnessSettings = async (
  db: CodevisorDatabaseService,
  harnesses: ReadonlyArray<Harness>
): Promise<ReadonlyArray<Harness>> => {
  const preferences = await readHarnessSettings(db)
  return harnesses.map((harness) => {
    const settings = preferences.get(harness.id) ?? {}
    const effective = effectiveHarnessPreference(settings)
    const desiredEnabled = effective.enabled ?? harness.desiredEnabled ?? harness.enabled
    return {
      ...harness,
      settings,
      desiredEnabled,
      enabled: desiredEnabled && harness.readiness.state === "ready"
    }
  })
}

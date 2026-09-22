import type { Harness, HarnessPreference, HarnessSettings } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { latestSyncTimestamp, nextSyncTimestamp, type SyncEntryRecord } from "@codevisor/sync"
import { Effect } from "effect"

/// The fleet catalog is the ONE desired-state document for harnesses: what
/// the user wants enabled and installed, everywhere. There is no
/// machine-local override layer — a machine either follows the catalog or,
/// for harnesses the catalog doesn't mention yet, its own discovery default.
/// Every write path (Settings toggle, Install, Uninstall, PATCH) lands here,
/// so the Settings list and the composer's picker can never disagree.
export const HARNESSES_SYNC_NAMESPACE = "harnesses"
/// Custom harness definitions edited on this machine keep their local copy
/// instead of following the shared definition. Unrelated to enable/install.
export const CUSTOM_HARNESS_LOCAL_EDITS_NAMESPACE = "local.harness-custom-overrides"
const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

export const harnessPreference = (value: unknown): HarnessPreference | undefined => {
  if (typeof value !== "object" || value === null) return undefined
  const candidate = value as Record<string, unknown>
  if (typeof candidate.enabled !== "boolean" || typeof candidate.installed !== "boolean")
    return undefined
  // Legacy `installed: false` recorded absence, never permission to uninstall.
  if (candidate.installed !== true && candidate.uninstall !== true) return undefined
  return { enabled: candidate.enabled, installed: candidate.installed }
}

export const readHarnessSettings = async (
  db: CodevisorDatabaseService
): Promise<Map<string, HarnessSettings>> => {
  const result = new Map<string, HarnessSettings>()
  for (const entry of await run(db.getSyncEntries(HARNESSES_SYNC_NAMESPACE))) {
    if (entry.deleted || entry.key.startsWith("custom:")) continue
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

/// Writes one harness's desired state into the fleet catalog, in the exact
/// shape the Settings page authors (name and symbol ride along so a row
/// written by a machine renders like one written by a client). Returns the
/// entries that changed so the caller can publish `sync.changed`.
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

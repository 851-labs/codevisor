import type { Harness, HarnessPreference, HarnessSettings } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { latestSyncTimestamp, nextSyncTimestamp } from "@codevisor/sync"
import { Effect } from "effect"

export const HARNESS_OVERRIDES_NAMESPACE = "local.harness-overrides"
const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

export const harnessPreference = (
  value: unknown,
  global = false
): HarnessPreference | undefined => {
  if (typeof value !== "object" || value === null) return undefined
  const candidate = value as Record<string, unknown>
  if (
    global &&
    (typeof candidate.enabled !== "boolean" || typeof candidate.installed !== "boolean")
  )
    return undefined
  // Legacy `installed: false` recorded absence, never permission to uninstall.
  if (global && candidate.installed !== true && candidate.uninstall !== true) return undefined
  const enabled = typeof candidate.enabled === "boolean" ? candidate.enabled : undefined
  const installed = typeof candidate.installed === "boolean" ? candidate.installed : undefined
  if (enabled === undefined && installed === undefined) return undefined
  return {
    ...(enabled === undefined ? {} : { enabled }),
    ...(installed === undefined ? {} : { installed })
  }
}

export const readHarnessSettings = async (
  db: CodevisorDatabaseService
): Promise<Map<string, HarnessSettings>> => {
  const [global, overrides, customs] = await Promise.all([
    run(db.getSyncEntries("harnesses")),
    run(db.getSyncEntries(HARNESS_OVERRIDES_NAMESPACE)),
    run(db.getSyncEntries("local.harness-custom-overrides"))
  ])
  const result = new Map<string, HarnessSettings>()
  for (const entry of global) {
    if (entry.deleted || entry.key.startsWith("custom:")) continue
    const preference = harnessPreference(entry.value, true)
    if (preference !== undefined) result.set(entry.key, { global: preference })
  }
  for (const entry of overrides) {
    if (entry.deleted) continue
    const preference = harnessPreference(entry.value)
    if (preference !== undefined)
      result.set(entry.key, { ...result.get(entry.key), override: preference })
  }
  for (const entry of customs) {
    if (!entry.deleted) {
      const current = result.get(entry.key)
      result.set(entry.key, { ...current, override: current?.override ?? {} })
    }
  }
  return result
}

export const effectiveHarnessPreference = (
  settings: HarnessSettings | undefined
): HarnessPreference => {
  const effective = settings?.override ?? settings?.global ?? {}
  return effective.installed === false ? { ...effective, enabled: false } : effective
}

export const setHarnessOverride = async (
  db: CodevisorDatabaseService,
  id: string,
  preference: HarnessPreference | undefined
): Promise<void> => {
  const entries = await run(db.getSyncEntries(HARNESS_OVERRIDES_NAMESPACE))
  const previous = entries.find((entry) => entry.key === id && !entry.deleted)
  await run(
    db.mergeSyncEntries(HARNESS_OVERRIDES_NAMESPACE, [
      {
        key: id,
        value:
          preference === undefined
            ? null
            : { ...harnessPreference(previous?.value), ...preference },
        ...(preference === undefined ? { deleted: true } : {}),
        timestamp: nextSyncTimestamp("local", latestSyncTimestamp(entries), Date.now())
      }
    ])
  )
  if (preference === undefined) {
    for (const namespace of ["local.harness-custom-overrides", "local.harnesses-applied"]) {
      const entries = await run(db.getSyncEntries(namespace))
      await run(
        db.mergeSyncEntries(namespace, [
          {
            key: namespace === "local.harnesses-applied" ? `custom:${id}` : id,
            value: null,
            deleted: true,
            timestamp: nextSyncTimestamp("local", latestSyncTimestamp(entries), Date.now())
          }
        ])
      )
    }
  }
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

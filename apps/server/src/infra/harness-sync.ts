import type { CustomHarnessSpec } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import {
  latestSyncTimestamp,
  nextSyncTimestamp,
  type SyncEntryRecord,
  type SyncTimestampValue
} from "@codevisor/sync"
import { Effect } from "effect"

/// Config-plane reconciliation for harnesses (agents). Two kinds of entry
/// share the "harnesses" namespace: catalog harnesses keyed by their id,
/// valued { enabled, installed } (the fleet's enabled set plus "the fleet
/// wants this installed"), and user-defined custom ACP harnesses keyed
/// "custom:<id>", valued as their full spec. Same three-way shape as the
/// other planes — a private dot-named applied namespace tells local edits
/// apart from replica lag — with one deliberate asymmetry: FIRST CONTACT
/// DEFERS TO THE FLEET. A fresh machine discovers every harness
/// default-enabled; letting that publish would re-enable a fleet's curated
/// set, so a never-applied key with a live replica entry adopts instead of
/// publishing. Enables are auth-gated (sign in first, retried each pass),
/// and desired installs run through the machine's own install methods —
/// missing methods report as blocked, never as failure.
export const HARNESSES_SYNC_NAMESPACE = "harnesses"
const APPLIED_NAMESPACE = "local.harnesses-applied"
const CUSTOM_PREFIX = "custom:"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

export interface LocalHarnessState {
  readonly id: string
  readonly enabled: boolean
  readonly installed: boolean
  /// Whether an enable may apply right now (signed in, or auth not needed).
  readonly authenticated: boolean
}

export interface HarnessSyncDeps {
  readonly db: CodevisorDatabaseService
  readonly serverId: string
  readonly now?: () => number
  readonly listHarnesses: () => Promise<ReadonlyArray<LocalHarnessState>>
  readonly setEnabled: (harnessId: string, enabled: boolean) => Promise<void>
  /// Starts a vendor install in the background; throws when no runnable
  /// method exists (surfaced as blocked and retried on a later pass).
  readonly beginInstall: (harnessId: string) => Promise<void>
  readonly listCustomSpecs: () => Promise<ReadonlyArray<CustomHarnessSpec>>
  readonly replaceCustomSpecs: (specs: ReadonlyArray<CustomHarnessSpec>) => Promise<void>
}

export interface HarnessSyncStatus {
  readonly published: ReadonlyArray<string>
  readonly applied: ReadonlyArray<string>
  readonly removed: ReadonlyArray<string>
  /// Installs started this pass (they finish in the background; the applied
  /// record lands on the pass that finds the binary present).
  readonly installing: ReadonlyArray<string>
  /// Waiting on this machine: a sign-in required before an enable applies,
  /// or no runnable install method. Retried on every pass.
  readonly blocked: ReadonlyArray<{ readonly id: string; readonly reason: string }>
}

export interface HarnessSyncResult {
  readonly status: HarnessSyncStatus
  readonly changedEntries: ReadonlyArray<SyncEntryRecord>
}

interface CatalogValue {
  readonly enabled: boolean
  readonly installed: boolean
}

const catalogValue = (value: unknown): CatalogValue | undefined => {
  if (typeof value !== "object" || value === null) return undefined
  const candidate = value as Partial<CatalogValue>
  if (typeof candidate.enabled !== "boolean") return undefined
  if (typeof candidate.installed !== "boolean") return undefined
  return { enabled: candidate.enabled, installed: candidate.installed }
}

/// One canonical field order (and sorted env keys) so fingerprints compare
/// equal regardless of which machine authored the value.
const normalizedSpec = (spec: CustomHarnessSpec): CustomHarnessSpec => ({
  id: spec.id,
  name: spec.name,
  command: spec.command,
  ...(spec.args === undefined ? {} : { args: [...spec.args] }),
  ...(spec.env === undefined
    ? {}
    : {
        env: Object.fromEntries(Object.entries(spec.env).sort(([a], [b]) => a.localeCompare(b)))
      })
})

const specValue = (value: unknown): CustomHarnessSpec | undefined => {
  if (typeof value !== "object" || value === null) return undefined
  const candidate = value as Partial<CustomHarnessSpec>
  if (typeof candidate.id !== "string") return undefined
  if (typeof candidate.name !== "string") return undefined
  if (typeof candidate.command !== "string") return undefined
  return normalizedSpec({
    id: candidate.id,
    name: candidate.name,
    command: candidate.command,
    ...(Array.isArray(candidate.args)
      ? { args: candidate.args.filter((item): item is string => typeof item === "string") }
      : {}),
    ...(typeof candidate.env === "object" && candidate.env !== null
      ? {
          env: Object.fromEntries(
            Object.entries(candidate.env).filter(
              (pair): pair is [string, string] => typeof pair[1] === "string"
            )
          )
        }
      : {})
  })
}

/// One reconcile pass; see the module doc for the model.
export const reconcileHarnesses = async (deps: HarnessSyncDeps): Promise<HarnessSyncResult> => {
  const now = deps.now ?? Date.now
  const locals = await deps.listHarnesses()
  const localById = new Map(locals.map((harness) => [harness.id, harness]))
  const customs = (await deps.listCustomSpecs()).map(normalizedSpec)
  const customByKey = new Map(customs.map((spec) => [`${CUSTOM_PREFIX}${spec.id}`, spec]))
  const replica = await run(deps.db.getSyncEntries(HARNESSES_SYNC_NAMESPACE))
  const replicaByKey = new Map(replica.map((entry) => [entry.key, entry]))
  const appliedEntries = await run(deps.db.getSyncEntries(APPLIED_NAMESPACE))
  const appliedByKey = new Map(
    appliedEntries
      .filter((entry) => entry.deleted !== true && typeof entry.value === "string")
      .map((entry) => [entry.key, entry.value as string])
  )

  const published: Array<string> = []
  const applied: Array<string> = []
  const removed: Array<string> = []
  const installing: Array<string> = []
  const blocked: Array<{ id: string; reason: string }> = []
  const replicaWrites: Array<SyncEntryRecord> = []
  const appliedWrites: Array<SyncEntryRecord> = []
  let clock: SyncTimestampValue | undefined = latestSyncTimestamp([...replica, ...appliedEntries])
  const stamp = (): SyncTimestampValue => {
    clock = nextSyncTimestamp(deps.serverId, clock, now())
    return clock
  }
  const liveReplicaValue = (key: string): unknown => {
    const entry = replicaByKey.get(key)
    return entry === undefined || entry.deleted === true ? undefined : entry.value
  }

  // ── Publish: catalog state. Local edits after adoption publish; first
  // contact with a live replica entry adopts below instead.
  for (const [id, local] of localById) {
    const replicaValue = catalogValue(liveReplicaValue(id))
    const value: CatalogValue = {
      enabled: local.enabled,
      // "Installed" is a fleet-desired flag: once any machine had it, it
      // stays wanted — there is no uninstall to publish.
      installed: local.installed || replicaValue?.installed === true
    }
    const fingerprint = JSON.stringify(value)
    if (appliedByKey.get(id) === fingerprint) continue
    if (!appliedByKey.has(id) && replicaValue !== undefined) continue
    replicaWrites.push({ key: id, value, timestamp: stamp() })
    appliedWrites.push({ key: id, value: fingerprint, timestamp: stamp() })
    appliedByKey.set(id, fingerprint)
    published.push(id)
  }

  // ── Publish: custom specs (creations and edits, same first-contact rule).
  for (const [key, spec] of customByKey) {
    const replicaSpec = specValue(liveReplicaValue(key))
    const fingerprint = JSON.stringify(spec)
    if (appliedByKey.get(key) === fingerprint) continue
    if (!appliedByKey.has(key) && replicaSpec !== undefined) continue
    replicaWrites.push({ key, value: spec, timestamp: stamp() })
    appliedWrites.push({ key, value: fingerprint, timestamp: stamp() })
    appliedByKey.set(key, fingerprint)
    published.push(key)
  }
  // Custom specs this machine once had that are gone were deleted here.
  for (const [key] of appliedByKey) {
    if (!key.startsWith(CUSTOM_PREFIX)) continue
    if (customByKey.has(key)) continue
    if (replicaByKey.get(key)?.deleted === true) continue
    replicaWrites.push({ key, value: null, deleted: true, timestamp: stamp() })
    appliedWrites.push({ key, value: null, deleted: true, timestamp: stamp() })
    published.push(key)
  }

  const changedEntries =
    replicaWrites.length > 0
      ? (await run(deps.db.mergeSyncEntries(HARNESSES_SYNC_NAMESPACE, replicaWrites))).changed
      : []
  const merged = await run(deps.db.getSyncEntries(HARNESSES_SYNC_NAMESPACE))

  // ── Apply: catalog entries. The applied record only lands once the local
  // machine fully matches the wanted value — auth-gated enables and
  // still-running installs stay pending and retry on later passes.
  for (const entry of merged) {
    if (entry.key.startsWith(CUSTOM_PREFIX)) continue
    if (entry.deleted === true) continue
    const local = localById.get(entry.key)
    if (local === undefined) continue
    const wanted = catalogValue(entry.value)
    if (wanted === undefined) continue
    const fingerprint = JSON.stringify(wanted)
    if (appliedByKey.get(entry.key) === fingerprint) continue
    let pending = false
    if (wanted.enabled !== local.enabled) {
      if (wanted.enabled && !local.authenticated) {
        blocked.push({ id: entry.key, reason: "Sign in before this harness can be enabled" })
        pending = true
      } else {
        await deps.setEnabled(entry.key, wanted.enabled)
      }
    }
    if (wanted.installed && !local.installed) {
      try {
        await deps.beginInstall(entry.key)
        installing.push(entry.key)
      } catch (cause) {
        blocked.push({
          id: entry.key,
          reason: cause instanceof Error ? cause.message : String(cause)
        })
      }
      pending = true
    }
    if (!pending) {
      appliedWrites.push({ key: entry.key, value: fingerprint, timestamp: stamp() })
      appliedByKey.set(entry.key, fingerprint)
      applied.push(entry.key)
    }
  }

  // ── Apply: custom specs, folded into one replace when anything changed.
  let customChanged = false
  const nextCustom = new Map(customs.map((spec) => [spec.id, spec]))
  for (const entry of merged) {
    if (!entry.key.startsWith(CUSTOM_PREFIX)) continue
    const id = entry.key.slice(CUSTOM_PREFIX.length)
    if (entry.deleted === true) {
      if (nextCustom.has(id) && appliedByKey.has(entry.key)) {
        nextCustom.delete(id)
        customChanged = true
        appliedWrites.push({ key: entry.key, value: null, deleted: true, timestamp: stamp() })
        appliedByKey.delete(entry.key)
        removed.push(entry.key)
      }
      continue
    }
    const spec = specValue(entry.value)
    if (spec === undefined || spec.id !== id) continue
    const fingerprint = JSON.stringify(spec)
    if (appliedByKey.get(entry.key) === fingerprint) continue
    nextCustom.set(id, spec)
    customChanged = true
    appliedWrites.push({ key: entry.key, value: fingerprint, timestamp: stamp() })
    appliedByKey.set(entry.key, fingerprint)
    applied.push(entry.key)
  }
  if (customChanged) {
    await deps.replaceCustomSpecs([...nextCustom.values()])
  }

  if (appliedWrites.length > 0) {
    await run(deps.db.mergeSyncEntries(APPLIED_NAMESPACE, appliedWrites))
  }
  return {
    status: { published, applied, removed, installing, blocked },
    changedEntries
  }
}

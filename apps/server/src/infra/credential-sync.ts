import type { CredentialSource } from "@codevisor/harness-manager"
import type { CodevisorDatabaseService } from "@codevisor/db"
import {
  latestSyncTimestamp,
  nextSyncTimestamp,
  type SyncEntryRecord,
  type SyncTimestampValue
} from "@codevisor/sync"
import { createHash } from "node:crypto"
import { Effect } from "effect"

/// Phase 20: config-plane reconciliation for STATIC harness credentials.
/// Same three-way shape as the other planes — a dot-named applied
/// namespace tells local edits apart from replica lag — over the file
/// layer's CredentialSource seam (packages/harness-manager). Values are
/// the sources' canonical content strings; what is static enough to
/// travel is decided entirely by the sources. First contact defers to
/// the fleet (a joining machine's differing local file adopts rather
/// than overwrites), and per-source failures are isolated: one broken
/// file surfaces in `failed` and retries next pass without stopping the
/// rest.
export const CREDENTIALS_SYNC_NAMESPACE = "harness-credentials"
const APPLIED_NAMESPACE = "local.credentials-applied"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const fingerprint = (content: string): string => createHash("sha256").update(content).digest("hex")

export interface CredentialSyncDeps {
  readonly db: CodevisorDatabaseService
  readonly serverId: string
  readonly sources: ReadonlyArray<CredentialSource>
  readonly now?: () => number
  /// Fired after ferried content lands locally, so the caller can force
  /// an auth probe (and the roster republish that rides on it).
  readonly onApplied?: (sourceId: string) => void
}

export interface CredentialSyncStatus {
  readonly published: ReadonlyArray<string>
  readonly applied: ReadonlyArray<string>
  readonly removed: ReadonlyArray<string>
  readonly failed: ReadonlyArray<{ readonly id: string; readonly reason: string }>
}

export interface CredentialSyncResult {
  readonly status: CredentialSyncStatus
  readonly changedEntries: ReadonlyArray<SyncEntryRecord>
}

const reasonOf = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

export const reconcileCredentials = async (
  deps: CredentialSyncDeps
): Promise<CredentialSyncResult> => {
  const now = deps.now ?? Date.now
  const replica = await run(deps.db.getSyncEntries(CREDENTIALS_SYNC_NAMESPACE))
  const replicaByKey = new Map(replica.map((entry) => [entry.key, entry]))
  const appliedEntries = await run(deps.db.getSyncEntries(APPLIED_NAMESPACE))
  const appliedByKey = new Map(
    appliedEntries
      .filter((entry) => entry.deleted !== true && typeof entry.value === "string")
      .map((entry) => [entry.key, entry.value as string])
  )
  let clock: SyncTimestampValue | undefined = latestSyncTimestamp([...replica, ...appliedEntries])
  const stamp = (): SyncTimestampValue => {
    clock = nextSyncTimestamp(deps.serverId, clock, now())
    return clock
  }

  const published: Array<string> = []
  const applied: Array<string> = []
  const removed: Array<string> = []
  const failed: Array<{ id: string; reason: string }> = []
  const replicaWrites: Array<SyncEntryRecord> = []
  const appliedWrites: Array<SyncEntryRecord> = []

  // ── Publish: local files into the replica.
  for (const source of deps.sources) {
    let local: string | undefined
    try {
      local = await source.read()
    } catch (cause) {
      failed.push({ id: source.id, reason: reasonOf(cause) })
      continue
    }
    const entry = replicaByKey.get(source.id)
    const live =
      entry !== undefined && entry.deleted !== true && typeof entry.value === "string"
        ? entry.value
        : undefined
    if (local !== undefined) {
      if (appliedByKey.get(source.id) === fingerprint(local)) continue
      if (!appliedByKey.has(source.id) && live !== undefined && live !== local) {
        // First contact with a differing fleet value: the apply pass
        // below adopts the fleet; a join never overwrites it.
        continue
      }
      if (live !== local) {
        replicaWrites.push({ key: source.id, value: local, timestamp: stamp() })
        published.push(source.id)
      }
      appliedWrites.push({ key: source.id, value: fingerprint(local), timestamp: stamp() })
      appliedByKey.set(source.id, fingerprint(local))
    } else if (source.tombstoneOnAbsence && appliedByKey.has(source.id) && live !== undefined) {
      // The file was signed out here; propagate the deletion.
      replicaWrites.push({ key: source.id, value: null, deleted: true, timestamp: stamp() })
      appliedWrites.push({ key: source.id, value: null, deleted: true, timestamp: stamp() })
      appliedByKey.delete(source.id)
      published.push(source.id)
    }
  }

  const changedEntries =
    replicaWrites.length > 0
      ? (await run(deps.db.mergeSyncEntries(CREDENTIALS_SYNC_NAMESPACE, replicaWrites))).changed
      : []
  const merged = await run(deps.db.getSyncEntries(CREDENTIALS_SYNC_NAMESPACE))

  // ── Apply: replica entries into local files.
  const sourceById = new Map(deps.sources.map((source) => [source.id, source]))
  for (const entry of merged) {
    const source = sourceById.get(entry.key)
    if (source === undefined) continue
    if (failed.some((failure) => failure.id === source.id)) continue
    if (entry.deleted === true) {
      if (source.applyDelete === undefined || !appliedByKey.has(source.id)) continue
      try {
        await source.applyDelete()
      } catch (cause) {
        failed.push({ id: source.id, reason: reasonOf(cause) })
        continue
      }
      appliedWrites.push({ key: source.id, value: null, deleted: true, timestamp: stamp() })
      appliedByKey.delete(source.id)
      removed.push(source.id)
      deps.onApplied?.(source.id)
      continue
    }
    if (typeof entry.value !== "string") continue
    if (appliedByKey.get(source.id) === fingerprint(entry.value)) continue
    try {
      await source.apply(entry.value)
    } catch (cause) {
      failed.push({ id: source.id, reason: reasonOf(cause) })
      continue
    }
    appliedWrites.push({ key: source.id, value: fingerprint(entry.value), timestamp: stamp() })
    appliedByKey.set(source.id, fingerprint(entry.value))
    applied.push(source.id)
    deps.onApplied?.(source.id)
  }

  if (appliedWrites.length > 0) {
    await run(deps.db.mergeSyncEntries(APPLIED_NAMESPACE, appliedWrites))
  }
  return { status: { published, applied, removed, failed }, changedEntries }
}

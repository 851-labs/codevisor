/// The config plane's one replication primitive: last-writer-wins entries
/// ordered by hybrid logical clocks. Deliberately NOT a CRDT framework —
/// see README.md for the model and its limits.

/// A hybrid logical clock stamp. Total order: wall clock, then the logical
/// counter (for writes inside one millisecond or on skewed clocks), then
/// the writing device id as a deterministic tiebreak. Every replica orders
/// any two stamps identically, so merges converge regardless of the order
/// updates arrive in.
export interface SyncTimestampValue {
  readonly wallMs: number
  readonly counter: number
  readonly deviceId: string
}

/// One replicated key. A deletion is a tombstone (`deleted: true`) so it
/// wins over an older write on replicas that never saw the key at all.
export interface SyncEntryRecord {
  readonly key: string
  readonly value: unknown
  readonly deleted?: boolean | undefined
  readonly timestamp: SyncTimestampValue
}

/// Negative when `a` is older than `b`, positive when newer, zero only for
/// an identical stamp.
export const compareSyncTimestamps = (a: SyncTimestampValue, b: SyncTimestampValue): number => {
  if (a.wallMs !== b.wallMs) return a.wallMs - b.wallMs
  if (a.counter !== b.counter) return a.counter - b.counter
  return a.deviceId < b.deviceId ? -1 : a.deviceId > b.deviceId ? 1 : 0
}

/// The next stamp a device should write with: at least the wall clock, and
/// strictly after everything it has seen — so causally later writes always
/// order later even across skewed clocks.
export const nextSyncTimestamp = (
  deviceId: string,
  after: SyncTimestampValue | undefined,
  nowMs: number
): SyncTimestampValue => {
  if (after === undefined || nowMs > after.wallMs) {
    return { wallMs: nowMs, counter: 0, deviceId }
  }
  return { wallMs: after.wallMs, counter: after.counter + 1, deviceId }
}

/// The newest stamp across a set of entries — what `nextSyncTimestamp`
/// should tick past when writing into a merged document.
export const latestSyncTimestamp = (
  entries: ReadonlyArray<SyncEntryRecord>
): SyncTimestampValue | undefined => {
  let latest: SyncTimestampValue | undefined
  for (const entry of entries) {
    if (latest === undefined || compareSyncTimestamps(entry.timestamp, latest) > 0) {
      latest = entry.timestamp
    }
  }
  return latest
}

export interface SyncMergeResult {
  /// The converged document, sorted by key for deterministic output.
  readonly merged: ReadonlyArray<SyncEntryRecord>
  /// The incoming entries that actually replaced (or introduced) local
  /// state — what a replica persists and republishes.
  readonly changed: ReadonlyArray<SyncEntryRecord>
}

/// Per-key last-writer-wins merge. Idempotent and commutative given the
/// total timestamp order, so replicas converge no matter how updates are
/// gossiped.
export const mergeSyncEntries = (
  current: ReadonlyArray<SyncEntryRecord>,
  incoming: ReadonlyArray<SyncEntryRecord>
): SyncMergeResult => {
  const byKey = new Map<string, SyncEntryRecord>()
  for (const entry of current) {
    byKey.set(entry.key, entry)
  }
  const changed: SyncEntryRecord[] = []
  for (const entry of incoming) {
    const existing = byKey.get(entry.key)
    if (existing === undefined || compareSyncTimestamps(entry.timestamp, existing.timestamp) > 0) {
      byKey.set(entry.key, entry)
      changed.push(entry)
    }
  }
  const merged = [...byKey.values()].sort((a, b) => a.key.localeCompare(b.key))
  return { merged, changed }
}

/// Namespaces are path segments and database keys; keep them boring.
export const isValidSyncNamespace = (value: string): boolean => /^[a-z][a-z0-9-]{0,63}$/.test(value)
export * from "./blob-store.js"
export * from "./tree-hash.js"

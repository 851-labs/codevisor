export interface SyncTimestampValue {
  readonly wallMs: number
  readonly counter: number
  readonly deviceId: string
}

export interface SyncEntryRecord {
  readonly key: string
  readonly value: unknown
  readonly deleted?: boolean | undefined
  readonly timestamp: SyncTimestampValue
}

export const compareSyncTimestamps = (a: SyncTimestampValue, b: SyncTimestampValue): number => {
  if (a.wallMs !== b.wallMs) return a.wallMs - b.wallMs
  if (a.counter !== b.counter) return a.counter - b.counter
  return a.deviceId < b.deviceId ? -1 : a.deviceId > b.deviceId ? 1 : 0
}

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
  readonly merged: ReadonlyArray<SyncEntryRecord>
  readonly changed: ReadonlyArray<SyncEntryRecord>
}

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
  const merged = [...byKey.values()].toSorted((a, b) => a.key.localeCompare(b.key))
  return { merged, changed }
}

export const isValidSyncNamespace = (value: string): boolean => /^[a-z][a-z0-9-]{0,63}$/.test(value)
export * from "./blob-store.js"
export * from "./tree-hash.js"

export const freeSyncKey = (base: string, taken: (candidate: string) => boolean): string => {
  let suffix = 2
  while (taken(`${base}-${suffix}`)) suffix += 1
  return `${base}-${suffix}`
}

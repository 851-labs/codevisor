import {
  latestSyncTimestamp,
  nextSyncTimestamp,
  type SyncEntryRecord,
  type SyncTimestampValue
} from "@codevisor/sync"

import { appliedValuesByKey } from "./applied-values.js"

export interface SyncLedgerSource {
  readonly owner: { readonly serverId: string }
  readonly replica: ReadonlyArray<SyncEntryRecord>
  readonly applied: ReadonlyArray<SyncEntryRecord>
  readonly sideEntries?: ReadonlyArray<SyncEntryRecord>
  readonly now?: () => number
}

export type Fingerprint = () => string

export interface SyncLedger {
  readonly applied: Map<string, string>
  readonly replicaWrites: ReadonlyArray<SyncEntryRecord>
  readonly appliedWrites: ReadonlyArray<SyncEntryRecord>
  readonly stamp: () => SyncTimestampValue
  readonly publish: (key: string, value: unknown, fingerprint: Fingerprint) => void
  readonly retract: (key: string) => void
  readonly markApplied: (key: string, fingerprint: Fingerprint) => void
  readonly markRemoved: (key: string) => void
  readonly retractUnlisted: (
    listed: ReadonlyMap<string, unknown>,
    replicaByKey: ReadonlyMap<string, SyncEntryRecord>,
    retracted: Array<string>
  ) => void
}

export const openSyncLedger = (source: SyncLedgerSource): SyncLedger => {
  const writes: LedgerWrites = {
    applied: appliedValuesByKey(source.applied),
    replicaWrites: [],
    appliedWrites: [],
    stamp: syncClock(source)
  }
  return {
    ...writes,
    publish: (key, value, fingerprint) => publish(writes, key, value, fingerprint),
    retract: (key) => retract(writes, key),
    markApplied: (key, fingerprint) => markApplied(writes, key, fingerprint),
    markRemoved: (key) => markRemoved(writes, key),
    retractUnlisted: (listed, replicaByKey, retracted) =>
      retractUnlisted(writes, listed, replicaByKey, retracted)
  }
}

interface LedgerWrites {
  readonly applied: Map<string, string>
  readonly replicaWrites: Array<SyncEntryRecord>
  readonly appliedWrites: Array<SyncEntryRecord>
  readonly stamp: () => SyncTimestampValue
}

const syncClock = (source: SyncLedgerSource): (() => SyncTimestampValue) => {
  const now = source.now ?? wallClock
  let clock = latestSyncTimestamp([
    ...source.replica,
    ...source.applied,
    ...(source.sideEntries ?? [])
  ])
  return () => {
    clock = nextSyncTimestamp(source.owner.serverId, clock, now())
    return clock
  }
}

const wallClock = (): number => Date.now()

const publish = (
  writes: LedgerWrites,
  key: string,
  value: unknown,
  fingerprint: Fingerprint
): void => {
  writes.replicaWrites.push({ key, value, timestamp: writes.stamp() })
  markApplied(writes, key, fingerprint)
}

const markApplied = (writes: LedgerWrites, key: string, fingerprint: Fingerprint): void => {
  writes.appliedWrites.push({ key, value: fingerprint(), timestamp: writes.stamp() })
  writes.applied.set(key, fingerprint())
}

const retract = (writes: LedgerWrites, key: string): void => {
  writes.replicaWrites.push(tombstone(key, writes.stamp()))
  writes.appliedWrites.push(tombstone(key, writes.stamp()))
}

const markRemoved = (writes: LedgerWrites, key: string): void => {
  writes.appliedWrites.push(tombstone(key, writes.stamp()))
  writes.applied.delete(key)
}

const retractUnlisted = (
  writes: LedgerWrites,
  listed: ReadonlyMap<string, unknown>,
  replicaByKey: ReadonlyMap<string, SyncEntryRecord>,
  retracted: Array<string>
): void => {
  for (const [key] of writes.applied) {
    if (listed.has(key)) continue
    if (replicaByKey.get(key)?.deleted === true) continue

    retract(writes, key)
    retracted.push(key)
  }
}

const tombstone = (key: string, timestamp: SyncTimestampValue): SyncEntryRecord => ({
  key,
  value: null,
  deleted: true,
  timestamp
})

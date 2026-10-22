import type { CodevisorDatabaseService } from "@codevisor/db"
import {
  latestSyncTimestamp,
  nextSyncTimestamp,
  type SyncEntryRecord,
  type SyncMergeResult,
  type SyncTimestampValue
} from "@codevisor/sync"
import { Effect } from "effect"

import { appliedValuesByKey } from "./applied-values.js"

export interface SyncOwner {
  readonly serverId: string
}

export interface SyncLedgerSource {
  readonly owner: SyncOwner
  readonly replica: ReadonlyArray<SyncEntryRecord>
  readonly applied: ReadonlyArray<SyncEntryRecord>
  readonly sideEntries?: ReadonlyArray<SyncEntryRecord>
  readonly now?: () => number
}

export type Fingerprint = () => string

export interface SyncStamps {
  readonly stamp: () => SyncTimestampValue
  readonly entry: (key: string, value: unknown) => SyncEntryRecord
  readonly tombstone: (key: string) => SyncEntryRecord
}

export interface SyncLedger extends SyncStamps {
  readonly applied: Map<string, string>
  readonly replicaWrites: ReadonlyArray<SyncEntryRecord>
  readonly appliedWrites: ReadonlyArray<SyncEntryRecord>
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

export interface SyncDatabase {
  readonly db: CodevisorDatabaseService
}

export const openSyncLedger = (source: SyncLedgerSource): SyncLedger => {
  const applied = appliedValuesByKey(source.applied)
  const now = source.now ?? wallClock
  const latest = latestSyncTimestamp([
    ...source.replica,
    ...source.applied,
    ...(source.sideEntries ?? [])
  ])
  const stamps = stampsAfter(latest, () => source.owner.serverId, now)
  const writes: LedgerWrites = {
    applied,
    replicaWrites: [],
    appliedWrites: [],
    stamp: stamps.stamp
  }
  return {
    ...writes,
    entry: stamps.entry,
    tombstone: stamps.tombstone,
    publish: (key, value, fingerprint) => publish(writes, key, value, fingerprint),
    retract: (key) => retract(writes, key),
    markApplied: (key, fingerprint) => markApplied(writes, key, fingerprint),
    markRemoved: (key) => markRemoved(writes, key),
    retractUnlisted: (listed, replicaByKey, retracted) =>
      retractUnlisted(writes, listed, replicaByKey, retracted)
  }
}

export const openSyncStamps = (
  owner: SyncOwner,
  entries: ReadonlyArray<SyncEntryRecord>,
  now: () => number = wallClock
): SyncStamps => stampsAfter(latestSyncTimestamp(entries), () => owner.serverId, now)

export const mergePending = (
  target: SyncDatabase,
  namespace: string,
  writes: ReadonlyArray<SyncEntryRecord>
): Promise<SyncMergeResult> | undefined => {
  if (writes.length === 0) return undefined
  return run(target.db.mergeSyncEntries(namespace, writes))
}

export const keyedEntries = (
  entries: ReadonlyArray<SyncEntryRecord>
): Map<string, SyncEntryRecord> => new Map(entries.map((entry) => [entry.key, entry]))

interface LedgerWrites {
  readonly applied: Map<string, string>
  readonly replicaWrites: Array<SyncEntryRecord>
  readonly appliedWrites: Array<SyncEntryRecord>
  readonly stamp: () => SyncTimestampValue
}

const stampsAfter = (
  latest: SyncTimestampValue | undefined,
  serverId: () => string,
  now: () => number
): SyncStamps => {
  let clock = latest
  const stamp = (): SyncTimestampValue => {
    clock = nextSyncTimestamp(serverId(), clock, now())
    return clock
  }
  return {
    stamp,
    entry: (key, value) => ({ key, value, timestamp: stamp() }),
    tombstone: (key) => tombstone(key, stamp())
  }
}

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

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

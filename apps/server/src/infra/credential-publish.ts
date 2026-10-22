import { createHash } from "node:crypto"

import type { CredentialSource } from "@codevisor/harness-manager"
import type { SyncEntryRecord } from "@codevisor/sync"

import type { CredentialSyncDeps } from "./credential-sync.js"
import { openSyncLedger, type SyncLedger } from "./sync-ledger.js"

export const PROFILES_KEY = "profiles:opencode"

export interface CredentialSync {
  readonly previousOverrides: ReadonlyMap<string, unknown>
  readonly ledger: SyncLedger
  readonly overrideWrites: Array<SyncEntryRecord>
  readonly published: Array<string>
  readonly applied: Array<string>
  readonly removed: Array<string>
  readonly failed: Array<CredentialFailure>
}

export interface CredentialRows {
  readonly replica: ReadonlyArray<SyncEntryRecord>
  readonly replicaByKey: ReadonlyMap<string, SyncEntryRecord>
  readonly appliedEntries: ReadonlyArray<SyncEntryRecord>
  readonly overrideEntries: ReadonlyArray<SyncEntryRecord>
}

export interface CredentialFailure {
  readonly id: string
  readonly reason: string
}

export interface LocalCredential {
  readonly content: string | undefined
  readonly overrides: ReadonlyArray<string>
}

type LocalCredentialStep = "skip" | "adopt" | "publish"

export const openCredentialSync = (
  deps: CredentialSyncDeps,
  now: () => number,
  rows: CredentialRows
): CredentialSync => {
  const previousOverrides = new Map(rows.overrideEntries.map((entry) => [entry.key, entry.value]))
  const ledger = openSyncLedger({
    owner: deps,
    now,
    replica: rows.replica,
    applied: rows.appliedEntries,
    sideEntries: rows.overrideEntries
  })
  return {
    previousOverrides,
    ledger,
    overrideWrites: [],
    published: [],
    applied: [],
    removed: [],
    failed: []
  }
}

export const publishLocalCredential = (
  sync: CredentialSync,
  source: CredentialSource,
  live: string | undefined,
  local: LocalCredential
): void => {
  if (local.content === undefined) {
    retractAbsentCredential(sync, source, local.overrides, live)
    return
  }
  publishPresentCredential(sync, source, live, local.content)
}

export const recordOverrides = (
  sync: CredentialSync,
  source: CredentialSource,
  previous: unknown,
  overrides: ReadonlyArray<string>
): void => {
  if (!overridesChanged(previous, overrides)) return

  sync.overrideWrites.push(sync.ledger.entry(source.id, [...overrides]))
}

export const recordApplied = (
  deps: CredentialSyncDeps,
  sync: CredentialSync,
  source: CredentialSource
): void => {
  sync.applied.push(source.id)
  deps.onApplied?.(source.id)
}

export const recordFailure = (sync: CredentialSync, id: string, cause: unknown): void => {
  sync.failed.push(failure(id, cause))
}

export const restoresLive = (
  live: string | undefined,
  previous: unknown,
  overrides: ReadonlyArray<string>
): live is string => live !== undefined && overrideDropped(previous, overrides)

export const hasFailed = (
  failed: ReadonlyArray<CredentialFailure>,
  source: CredentialSource
): boolean => failed.some((recorded) => recorded.id === source.id)

export const fingerprint = (content: string): string =>
  createHash("sha256").update(content).digest("hex")

export const profilesContent = (profiles: SyncEntryRecord): string | undefined =>
  profiles.deleted === true ? undefined : String(profiles.value)

export const liveCredential = (entry: SyncEntryRecord | undefined): string | undefined => {
  if (entry === undefined || entry.deleted === true) return undefined
  return typeof entry.value === "string" ? entry.value : undefined
}

const retractAbsentCredential = (
  sync: CredentialSync,
  source: CredentialSource,
  overrides: ReadonlyArray<string>,
  live: string | undefined
): void => {
  if (keepsReplicaWhenAbsent(sync.ledger, source, overrides, live)) return

  sync.ledger.retract(source.id)
  sync.ledger.applied.delete(source.id)
  sync.published.push(source.id)
}

const publishPresentCredential = (
  sync: CredentialSync,
  source: CredentialSource,
  live: string | undefined,
  local: string
): void => {
  const localFingerprint = fingerprint(local)
  const step = localCredentialStep(sync.ledger, source.id, live, local, localFingerprint)
  if (step === "skip") return
  if (step === "adopt") {
    sync.ledger.markApplied(source.id, () => localFingerprint)
    return
  }

  sync.ledger.publish(source.id, local, () => localFingerprint)
  sync.published.push(source.id)
}

const overrideDropped = (previous: unknown, overrides: ReadonlyArray<string>): boolean =>
  Array.isArray(previous) && previous.some((key) => !overrides.includes(String(key)))

const overridesChanged = (previous: unknown, overrides: ReadonlyArray<string>): boolean =>
  JSON.stringify(previous ?? []) !== JSON.stringify(overrides)

const keepsReplicaWhenAbsent = (
  ledger: SyncLedger,
  source: CredentialSource,
  overrides: ReadonlyArray<string>,
  live: string | undefined
): boolean =>
  !source.tombstoneOnAbsence ||
  overrides.length !== 0 ||
  !ledger.applied.has(source.id) ||
  live === undefined

const localCredentialStep = (
  ledger: SyncLedger,
  id: string,
  live: string | undefined,
  local: string,
  localFingerprint: string
): LocalCredentialStep => {
  if (ledger.applied.get(id) === localFingerprint) return "skip"
  if (replicaGoesFirst(ledger, id, live, local)) return "skip"
  if (live === local) return "adopt"
  return "publish"
}

const replicaGoesFirst = (
  ledger: SyncLedger,
  id: string,
  live: string | undefined,
  local: string
): boolean => !ledger.applied.has(id) && live !== undefined && live !== local

const failure = (id: string, cause: unknown): CredentialFailure => ({
  id,
  reason: cause instanceof Error ? cause.message : String(cause)
})

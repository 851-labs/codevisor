import { createHash } from "node:crypto"

import type { CodevisorDatabaseService } from "@codevisor/db"
import type { CredentialSource } from "@codevisor/harness-manager"
import type { SyncEntryRecord } from "@codevisor/sync"
import { Effect } from "effect"

import { openSyncLedger, type SyncLedger } from "./sync-ledger.js"

export const CREDENTIALS_SYNC_NAMESPACE = "harness-credentials"
const APPLIED_NAMESPACE = "local.credentials-applied"
const OVERRIDES_NAMESPACE = "local.credential-overrides"
const PROFILES_KEY = "profiles:opencode"

export interface CredentialSyncDeps {
  readonly db: CodevisorDatabaseService
  readonly serverId: string
  readonly sources: ReadonlyArray<CredentialSource>
  readonly profileSources?:
    | ((content?: string) => Promise<ReadonlyArray<CredentialSource>>)
    | undefined
  readonly now?: () => number
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

export const reconcileCredentials = async (
  deps: CredentialSyncDeps
): Promise<CredentialSyncResult> => {
  const now = deps.now ?? Date.now
  const replica = await run(deps.db.getSyncEntries(CREDENTIALS_SYNC_NAMESPACE))
  const replicaByKey = new Map(replica.map((entry) => [entry.key, entry]))
  const appliedEntries = await run(deps.db.getSyncEntries(APPLIED_NAMESPACE))
  const overrideEntries = await run(deps.db.getSyncEntries(OVERRIDES_NAMESPACE))
  const previousOverrides = new Map(overrideEntries.map((entry) => [entry.key, entry.value]))
  const ledger = openSyncLedger({
    owner: deps,
    now,
    replica,
    applied: appliedEntries,
    sideEntries: overrideEntries
  })

  const published: Array<string> = []
  const applied: Array<string> = []
  const removed: Array<string> = []
  const failed: Array<CredentialFailure> = []
  const overrideWrites: Array<SyncEntryRecord> = []

  const sources = [...deps.sources]
  const profiles = replicaByKey.get(PROFILES_KEY)
  if (profiles !== undefined && deps.profileSources !== undefined) {
    try {
      sources.push(...(await deps.profileSources(profilesContent(profiles))))
    } catch (cause) {
      failed.push(failure(PROFILES_KEY, cause))
    }
  }

  for (const source of sources) {
    const live = liveCredential(replicaByKey.get(source.id))
    let local: string | undefined
    let overrides: ReadonlyArray<string> = []
    try {
      overrides = (await source.localOverrides?.()) ?? []
      const previous = previousOverrides.get(source.id)
      if (live !== undefined && overrideDropped(previous, overrides)) {
        await source.apply(live)
        applied.push(source.id)
        deps.onApplied?.(source.id)
      }
      local = await source.read(live)
      if (overridesChanged(previous, overrides)) {
        overrideWrites.push({ key: source.id, value: [...overrides], timestamp: ledger.stamp() })
      }
    } catch (cause) {
      failed.push(failure(source.id, cause))
      continue
    }

    if (local === undefined) {
      if (keepsReplicaWhenAbsent(ledger, source, overrides, live)) continue

      ledger.retract(source.id)
      ledger.applied.delete(source.id)
      published.push(source.id)
      continue
    }

    const localFingerprint = fingerprint(local)
    const step = localCredentialStep(ledger, source.id, live, local, localFingerprint)
    if (step === "skip") continue
    if (step === "adopt") {
      ledger.markApplied(source.id, () => localFingerprint)
      continue
    }

    ledger.publish(source.id, local, () => localFingerprint)
    published.push(source.id)
  }

  let changedEntries: ReadonlyArray<SyncEntryRecord> = []
  if (ledger.replicaWrites.length > 0) {
    changedEntries = (
      await run(deps.db.mergeSyncEntries(CREDENTIALS_SYNC_NAMESPACE, ledger.replicaWrites))
    ).changed
  }
  const merged = await run(deps.db.getSyncEntries(CREDENTIALS_SYNC_NAMESPACE))

  const sourceById = new Map(sources.map((source) => [source.id, source]))
  for (const entry of merged) {
    const source = sourceById.get(entry.key)
    if (source === undefined || hasFailed(failed, source)) continue

    if (entry.deleted === true) {
      if (source.applyDelete === undefined || !ledger.applied.has(source.id)) continue

      try {
        await source.applyDelete()
      } catch (cause) {
        failed.push(failure(source.id, cause))
        continue
      }
      ledger.markRemoved(source.id)
      removed.push(source.id)
      deps.onApplied?.(source.id)
      continue
    }

    const content = entry.value
    if (typeof content !== "string") continue
    if (ledger.applied.get(source.id) === fingerprint(content)) continue

    try {
      await source.apply(content)
    } catch (cause) {
      failed.push(failure(source.id, cause))
      continue
    }
    ledger.markApplied(source.id, () => fingerprint(content))
    applied.push(source.id)
    deps.onApplied?.(source.id)
  }

  if (ledger.appliedWrites.length > 0) {
    await run(deps.db.mergeSyncEntries(APPLIED_NAMESPACE, ledger.appliedWrites))
  }
  if (overrideWrites.length > 0) {
    await run(deps.db.mergeSyncEntries(OVERRIDES_NAMESPACE, overrideWrites))
  }
  return { status: { published, applied, removed, failed }, changedEntries }
}

type LocalCredentialStep = "skip" | "adopt" | "publish"

interface CredentialFailure {
  readonly id: string
  readonly reason: string
}

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const fingerprint = (content: string): string => createHash("sha256").update(content).digest("hex")

const profilesContent = (profiles: SyncEntryRecord): string | undefined =>
  profiles.deleted === true ? undefined : String(profiles.value)

const liveCredential = (entry: SyncEntryRecord | undefined): string | undefined => {
  if (entry === undefined || entry.deleted === true) return undefined
  return typeof entry.value === "string" ? entry.value : undefined
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

const hasFailed = (failed: ReadonlyArray<CredentialFailure>, source: CredentialSource): boolean =>
  failed.some((failure) => failure.id === source.id)

const failure = (id: string, cause: unknown): CredentialFailure => ({
  id,
  reason: cause instanceof Error ? cause.message : String(cause)
})

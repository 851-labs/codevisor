import type { CodevisorDatabaseService } from "@codevisor/db"
import type { CredentialSource } from "@codevisor/harness-manager"
import type { SyncEntryRecord } from "@codevisor/sync"
import { Effect } from "effect"

import {
  type CredentialSync,
  fingerprint,
  hasFailed,
  liveCredential,
  type LocalCredential,
  openCredentialSync,
  PROFILES_KEY,
  profilesContent,
  publishLocalCredential,
  recordApplied,
  recordFailure,
  recordOverrides,
  restoresLive
} from "./credential-publish.js"
import { keyedEntries, mergePending, type SyncLedger } from "./sync-ledger.js"

export const CREDENTIALS_SYNC_NAMESPACE = "harness-credentials"
const APPLIED_NAMESPACE = "local.credentials-applied"
const OVERRIDES_NAMESPACE = "local.credential-overrides"

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
  const replicaByKey = keyedEntries(replica)
  const appliedEntries = await run(deps.db.getSyncEntries(APPLIED_NAMESPACE))
  const overrideEntries = await run(deps.db.getSyncEntries(OVERRIDES_NAMESPACE))
  const sync = openCredentialSync(deps, now, {
    replica,
    replicaByKey,
    appliedEntries,
    overrideEntries
  })

  const sources = [...deps.sources]
  const profiles = replicaByKey.get(PROFILES_KEY)
  if (profiles !== undefined && deps.profileSources !== undefined) {
    try {
      sources.push(...(await deps.profileSources(profilesContent(profiles))))
    } catch (cause) {
      recordFailure(sync, PROFILES_KEY, cause)
    }
  }

  for (const source of sources) {
    const live = liveCredential(replicaByKey.get(source.id))
    let local: LocalCredential
    try {
      const overrides = (await source.localOverrides?.()) ?? []
      const previous = sync.previousOverrides.get(source.id)
      if (restoresLive(live, previous, overrides)) {
        await source.apply(live)
        recordApplied(deps, sync, source)
      }
      local = { content: await source.read(live), overrides }
      recordOverrides(sync, source, previous, overrides)
    } catch (cause) {
      recordFailure(sync, source.id, cause)
      continue
    }
    publishLocalCredential(sync, source, live, local)
  }

  let changedEntries: ReadonlyArray<SyncEntryRecord> = []
  const replicaMerge = mergePending(deps, CREDENTIALS_SYNC_NAMESPACE, sync.ledger.replicaWrites)
  if (replicaMerge !== undefined) changedEntries = (await replicaMerge).changed
  const merged = await run(deps.db.getSyncEntries(CREDENTIALS_SYNC_NAMESPACE))

  const sourceById = new Map(sources.map((source) => [source.id, source]))
  for (const entry of merged) {
    const source = sourceToApply(sync, sourceById, entry.key)
    if (source === undefined) continue

    if (entry.deleted === true) {
      if (!canApplyDelete(sync.ledger, source)) continue

      try {
        await source.applyDelete()
      } catch (cause) {
        recordFailure(sync, source.id, cause)
        continue
      }
      recordRemoved(deps, sync, source)
      continue
    }

    const content = entry.value
    if (!needsApply(sync.ledger, source, content)) continue

    try {
      await source.apply(content)
    } catch (cause) {
      recordFailure(sync, source.id, cause)
      continue
    }
    recordReceived(deps, sync, source, content)
  }

  const appliedMerge = mergePending(deps, APPLIED_NAMESPACE, sync.ledger.appliedWrites)
  if (appliedMerge !== undefined) await appliedMerge
  const overrideMerge = mergePending(deps, OVERRIDES_NAMESPACE, sync.overrideWrites)
  if (overrideMerge !== undefined) await overrideMerge
  return { status: credentialStatus(sync), changedEntries }
}

type DeletableSource = CredentialSource & { readonly applyDelete: () => Promise<void> }

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const sourceToApply = (
  sync: CredentialSync,
  sourceById: ReadonlyMap<string, CredentialSource>,
  key: string
): CredentialSource | undefined => {
  const source = sourceById.get(key)
  if (source === undefined || hasFailed(sync.failed, source)) return undefined
  return source
}

const canApplyDelete = (ledger: SyncLedger, source: CredentialSource): source is DeletableSource =>
  source.applyDelete !== undefined && ledger.applied.has(source.id)

const needsApply = (
  ledger: SyncLedger,
  source: CredentialSource,
  content: unknown
): content is string =>
  typeof content === "string" && ledger.applied.get(source.id) !== fingerprint(content)

const recordRemoved = (
  deps: CredentialSyncDeps,
  sync: CredentialSync,
  source: CredentialSource
): void => {
  sync.ledger.markRemoved(source.id)
  sync.removed.push(source.id)
  deps.onApplied?.(source.id)
}

const recordReceived = (
  deps: CredentialSyncDeps,
  sync: CredentialSync,
  source: CredentialSource,
  content: string
): void => {
  sync.ledger.markApplied(source.id, () => fingerprint(content))
  sync.applied.push(source.id)
  deps.onApplied?.(source.id)
}

const credentialStatus = (sync: CredentialSync): CredentialSyncStatus => ({
  published: sync.published,
  applied: sync.applied,
  removed: sync.removed,
  failed: sync.failed
})

import type { McpServer } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { McpManager } from "@codevisor/mcp"
import { freeSyncKey, type SyncEntryRecord } from "@codevisor/sync"
import { Effect } from "effect"

import {
  fingerprint,
  type HeldCredential,
  mcpCreation,
  mcpUpdate,
  parseSyncedValue,
  syncedValue,
  type StaticMcpSecrets,
  type SyncedMcpValue,
  withCredential,
  withHeldCredential,
  withLegacyOAuth
} from "./mcp-sync-values.js"
import { keyedEntries, mergePending, openSyncLedger, type SyncLedger } from "./sync-ledger.js"

export {
  ACCOUNTS_SYNC_NAMESPACE,
  type AccountsRosterDeps,
  HARNESS_READINESS_NAMESPACE,
  type HarnessReadinessRow,
  PLUGIN_READINESS_NAMESPACE,
  type PluginReadinessRow,
  publishAccountsRoster,
  publishMachineReadiness
} from "./fleet-readiness.js"

export const MCPS_SYNC_NAMESPACE = "mcps"
const MCPS_APPLIED_NAMESPACE = "local.mcps-applied"

export interface McpSyncStatus {
  readonly published: ReadonlyArray<string>
  readonly applied: ReadonlyArray<string>
  readonly removed: ReadonlyArray<string>
  readonly renamed: ReadonlyArray<McpRename>
}

export interface McpSyncDeps {
  readonly db: CodevisorDatabaseService
  readonly mcp: McpManager
  readonly serverId: string
  readonly now?: () => number
}

export interface McpSyncResult {
  readonly status: McpSyncStatus
  readonly changedEntries: ReadonlyArray<SyncEntryRecord>
}

export const reconcileMcps = async (deps: McpSyncDeps): Promise<McpSyncResult> => {
  const now = deps.now ?? Date.now
  const locals = (await deps.mcp.list()).filter((server) => server.kind === "managed")
  const localByName = new Map(locals.map((server) => [server.name, server]))
  const replica = await run(deps.db.getSyncEntries(MCPS_SYNC_NAMESPACE))
  const replicaByKey = keyedEntries(replica)
  const appliedEntries = await run(deps.db.getSyncEntries(MCPS_APPLIED_NAMESPACE))
  const ledger = openSyncLedger({ owner: deps, now, replica, applied: appliedEntries })
  const sync = openMcpSync(localByName, replicaByKey, ledger)

  for (const [name, server] of Array.from(localByName)) {
    const existing = replicaByKey.get(name)
    const wanted = replicatedMcp(existing)
    let credential: HeldCredential
    if (server.authType === "oauth") credential = await deps.mcp.oauthCredential(server.id)
    const secrets = await deps.mcp.staticSecrets(server.id)
    const value = withCredential(syncedValue(server, secrets), credential)
    const step = localMcpStep(ledger, name, value, wanted)
    if (step === "skip") continue
    if (step === "adopt") {
      ledger.markApplied(name, () => fingerprint(value))
      continue
    }
    if (step === "publish") {
      publishMcp(sync, name, value, existing?.value)
      continue
    }

    const key = freeMcpName(sync, name)
    await deps.mcp.update(server.id, { name: key })
    publishMcp(sync, key, renameLocalMcp(sync, name, server, value, key), undefined)
  }
  ledger.retractUnlisted(localByName, replicaByKey, sync.published)

  let changedEntries: ReadonlyArray<SyncEntryRecord> = []
  const replicaMerge = mergePending(deps, MCPS_SYNC_NAMESPACE, ledger.replicaWrites)
  if (replicaMerge !== undefined) changedEntries = (await replicaMerge).changed
  const merged = await run(deps.db.getSyncEntries(MCPS_SYNC_NAMESPACE))

  for (const entry of merged) {
    const name = entry.key
    const local = localByName.get(name)
    if (entry.deleted === true) {
      if (local === undefined) continue

      const secrets = await deps.mcp.staticSecrets(local.id)
      if (!isUnchangedMcp(ledger, name, local, secrets)) continue

      await deps.mcp.remove(local.id)
      ledger.markRemoved(name)
      sync.removed.push(name)
      continue
    }

    const received = parseSyncedValue(entry.value)
    if (received === undefined) continue

    let held: HeldCredential
    if (holdsOAuth(local, received)) held = await deps.mcp.oauthCredential(local.id)
    const wanted = withHeldCredential(received, held)
    recordRepair(sync, name, entry, received, wanted)
    const wantedFingerprint = fingerprint(wanted)
    if (ledger.applied.get(name) === wantedFingerprint) continue

    const installed = await installMcp(deps, local, wanted)
    if (wanted.oauthCredential !== undefined) {
      await deps.mcp.setOAuthCredential(credentialOwner(local, installed), wanted.oauthCredential)
    }
    ledger.markApplied(name, () => wantedFingerprint)
    sync.applied.push(name)
  }

  let repairedEntries: ReadonlyArray<SyncEntryRecord> = []
  const repairMerge = mergePending(deps, MCPS_SYNC_NAMESPACE, sync.repairs)
  if (repairMerge !== undefined) repairedEntries = (await repairMerge).changed
  for (const repair of sync.repairs) sync.published.push(repair.key)
  const appliedMerge = mergePending(deps, MCPS_APPLIED_NAMESPACE, ledger.appliedWrites)
  if (appliedMerge !== undefined) await appliedMerge
  return {
    status: mcpStatus(sync),
    changedEntries: [...changedEntries, ...repairedEntries]
  }
}

interface McpRename {
  readonly from: string
  readonly to: string
}

interface McpSync {
  readonly localByName: Map<string, McpServer>
  readonly replicaByKey: ReadonlyMap<string, SyncEntryRecord>
  readonly ledger: SyncLedger
  readonly repairs: Array<SyncEntryRecord>
  readonly published: Array<string>
  readonly renamed: Array<McpRename>
  readonly applied: Array<string>
  readonly removed: Array<string>
}

type LocalMcpStep = "skip" | "publish" | "adopt" | "rename"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const openMcpSync = (
  localByName: Map<string, McpServer>,
  replicaByKey: ReadonlyMap<string, SyncEntryRecord>,
  ledger: SyncLedger
): McpSync => ({
  localByName,
  replicaByKey,
  ledger,
  repairs: [],
  published: [],
  renamed: [],
  applied: [],
  removed: []
})

const replicatedMcp = (existing: SyncEntryRecord | undefined): SyncedMcpValue | undefined =>
  existing?.deleted === true ? undefined : parseSyncedValue(existing?.value)

const localMcpStep = (
  ledger: SyncLedger,
  name: string,
  value: SyncedMcpValue,
  wanted: SyncedMcpValue | undefined
): LocalMcpStep => {
  if (ledger.applied.get(name) === fingerprint(value)) return "skip"
  if (!replicaClaimsName(ledger, name, wanted)) return "publish"
  if (fingerprint(wanted) === fingerprint(value)) return "adopt"
  return "rename"
}

const freeMcpName = (sync: McpSync, name: string): string =>
  freeSyncKey(name, (candidate) => nameTaken(sync, candidate))

const renameLocalMcp = (
  sync: McpSync,
  name: string,
  server: McpServer,
  value: SyncedMcpValue,
  key: string
): SyncedMcpValue => {
  sync.localByName.delete(name)
  sync.localByName.set(key, { ...server, name: key })
  const renamed = { ...value, name: key }
  sync.renamed.push({ from: name, to: key })
  return renamed
}

const publishMcp = (sync: McpSync, key: string, value: SyncedMcpValue, previous: unknown): void => {
  sync.ledger.publish(key, withLegacyOAuth(value, previous), () => fingerprint(value))
  sync.published.push(key)
}

const isUnchangedMcp = (
  ledger: SyncLedger,
  name: string,
  local: McpServer,
  secrets: StaticMcpSecrets
): boolean => ledger.applied.get(name) === fingerprint(syncedValue(local, secrets))

const holdsOAuth = (local: McpServer | undefined, received: SyncedMcpValue): local is McpServer =>
  local !== undefined && received.authType === "oauth"

const recordRepair = (
  sync: McpSync,
  name: string,
  entry: SyncEntryRecord,
  received: SyncedMcpValue,
  wanted: SyncedMcpValue
): void => {
  if (wanted === received) return

  sync.repairs.push(sync.ledger.entry(name, withLegacyOAuth(wanted, entry.value)))
}

const installMcp = (
  deps: McpSyncDeps,
  local: McpServer | undefined,
  wanted: SyncedMcpValue
): Promise<McpServer> => {
  if (local === undefined) return deps.mcp.create(mcpCreation(wanted))
  return deps.mcp.update(local.id, mcpUpdate(local, wanted))
}

const credentialOwner = (local: McpServer | undefined, installed: McpServer): string =>
  local === undefined ? installed.id : local.id

const replicaClaimsName = (
  ledger: SyncLedger,
  name: string,
  wanted: SyncedMcpValue | undefined
): wanted is SyncedMcpValue => !ledger.applied.has(name) && wanted !== undefined

const nameTaken = (sync: McpSync, candidate: string): boolean =>
  sync.localByName.has(candidate) || sync.replicaByKey.has(candidate)

const mcpStatus = (sync: McpSync): McpSyncStatus => ({
  published: sync.published,
  applied: sync.applied,
  removed: sync.removed,
  renamed: sync.renamed
})

import type { CodevisorDatabaseService } from "@codevisor/db"
import { readPluginInstallReceipt } from "@codevisor/plugins"
import type { SyncEntryRecord } from "@codevisor/sync"
import { Effect } from "effect"

import { openSyncLedger, type SyncLedger } from "./sync-ledger.js"

export const PLUGINS_SYNC_NAMESPACE = "plugins"
const APPLIED_NAMESPACE = "local.plugins-applied"

export const pluginSyncOrigin = (pluginPath: string): string | undefined => {
  const receipt = readPluginInstallReceipt(pluginPath)
  if (receipt === undefined) return undefined
  const source = receipt.source
  if (source.kind === "github") return source.repo ?? source.url
  if (source.kind === "git") return source.url
  return undefined
}

export interface LocalPluginState {
  readonly id: string
  readonly enabled: boolean
  readonly origin?: string | undefined
}

export interface PluginSyncDeps {
  readonly db: CodevisorDatabaseService
  readonly serverId: string
  readonly listPlugins: () => Promise<ReadonlyArray<LocalPluginState>>
  readonly installFromSource: (source: string) => Promise<void>
  readonly setEnabled: (pluginId: string, enabled: boolean) => Promise<void>
  readonly removePlugin: (pluginId: string) => Promise<void>
}

export interface PluginSyncStatus {
  readonly published: ReadonlyArray<string>
  readonly applied: ReadonlyArray<string>
  readonly removed: ReadonlyArray<string>
  readonly installed: ReadonlyArray<string>
  readonly blocked: ReadonlyArray<{ readonly id: string; readonly reason: string }>
}

export interface PluginSyncResult {
  readonly status: PluginSyncStatus
  readonly changedEntries: ReadonlyArray<SyncEntryRecord>
}

export const reconcilePlugins = async (deps: PluginSyncDeps): Promise<PluginSyncResult> => {
  const locals = await deps.listPlugins()
  const localById = new Map(locals.map((plugin) => [plugin.id, plugin]))
  const replica = await run(deps.db.getSyncEntries(PLUGINS_SYNC_NAMESPACE))
  const replicaByKey = new Map(replica.map((entry) => [entry.key, entry]))
  const appliedEntries = await run(deps.db.getSyncEntries(APPLIED_NAMESPACE))
  const ledger = openSyncLedger({ owner: deps, replica, applied: appliedEntries })

  const published = publishLocalPlugins(ledger, locals, replicaByKey)
  ledger.retractUnlisted(localById, replicaByKey, published)

  let changedEntries: ReadonlyArray<SyncEntryRecord> = []
  if (ledger.replicaWrites.length > 0) {
    changedEntries = (
      await run(deps.db.mergeSyncEntries(PLUGINS_SYNC_NAMESPACE, ledger.replicaWrites))
    ).changed
  }
  const merged = await run(deps.db.getSyncEntries(PLUGINS_SYNC_NAMESPACE))

  const applied: Array<string> = []
  const removed: Array<string> = []
  const installed: Array<string> = []
  const blocked: Array<PluginBlockage> = []
  for (const entry of merged) {
    if (entry.deleted === true) {
      if (!isAppliedLocal(ledger, localById, entry.key)) continue

      try {
        await deps.removePlugin(entry.key)
      } catch (cause) {
        blocked.push(blockage(entry.key, cause))
        continue
      }
      ledger.markRemoved(entry.key)
      removed.push(entry.key)
      continue
    }

    const wanted = pluginValue(entry.value)
    if (wanted === undefined) continue

    const fingerprint = JSON.stringify(wanted)
    if (ledger.applied.get(entry.key) === fingerprint) continue

    const local = localById.get(entry.key)
    if (local === undefined) {
      try {
        await deps.installFromSource(wanted.source)
        installed.push(entry.key)
        if (!wanted.enabled) await deps.setEnabled(entry.key, false)
      } catch (cause) {
        blocked.push(blockage(entry.key, cause))
        continue
      }
    } else if (local.origin === undefined) {
      continue
    } else if (local.enabled !== wanted.enabled) {
      await deps.setEnabled(entry.key, wanted.enabled)
    }
    ledger.markApplied(entry.key, () => fingerprint)
    applied.push(entry.key)
  }

  if (ledger.appliedWrites.length > 0) {
    await run(deps.db.mergeSyncEntries(APPLIED_NAMESPACE, ledger.appliedWrites))
  }
  return {
    status: { published, applied, removed, installed, blocked },
    changedEntries
  }
}

interface PluginValue {
  readonly enabled: boolean
  readonly source: string
}

interface PluginBlockage {
  readonly id: string
  readonly reason: string
}

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const publishLocalPlugins = (
  ledger: SyncLedger,
  locals: ReadonlyArray<LocalPluginState>,
  replicaByKey: ReadonlyMap<string, SyncEntryRecord>
): Array<string> => {
  const published: Array<string> = []
  for (const plugin of locals) {
    if (plugin.origin === undefined) continue

    const replicaValue = livePluginValue(replicaByKey.get(plugin.id))
    const value: PluginValue = { enabled: plugin.enabled, source: plugin.origin }
    const fingerprint = JSON.stringify(value)
    if (ledger.applied.get(plugin.id) === fingerprint) continue
    if (replicaGoesFirst(ledger, plugin.id, replicaValue)) continue

    ledger.publish(plugin.id, value, () => fingerprint)
    published.push(plugin.id)
  }
  return published
}

const replicaGoesFirst = (
  ledger: SyncLedger,
  id: string,
  replicaValue: PluginValue | undefined
): boolean => !ledger.applied.has(id) && replicaValue !== undefined

const isAppliedLocal = (
  ledger: SyncLedger,
  localById: ReadonlyMap<string, LocalPluginState>,
  id: string
): boolean => localById.has(id) && ledger.applied.has(id)

const livePluginValue = (entry: SyncEntryRecord | undefined): PluginValue | undefined => {
  if (entry === undefined || entry.deleted === true) return undefined
  return pluginValue(entry.value)
}

const pluginValue = (value: unknown): PluginValue | undefined => {
  if (typeof value !== "object" || value === null) return undefined
  const candidate = value as Partial<PluginValue>
  if (typeof candidate.enabled !== "boolean") return undefined
  if (typeof candidate.source !== "string") return undefined
  return { enabled: candidate.enabled, source: candidate.source }
}

const blockage = (id: string, cause: unknown): PluginBlockage => ({
  id,
  reason: cause instanceof Error ? cause.message : String(cause)
})

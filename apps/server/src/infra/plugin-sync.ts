import type { CodevisorDatabaseService } from "@codevisor/db"
import { readPluginInstallReceipt } from "@codevisor/plugins"
import type { SyncEntryRecord } from "@codevisor/sync"
import { Effect } from "effect"

import { flushPending, keyedEntries, openSyncLedger, type SyncLedger } from "./sync-ledger.js"

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
  const replicaByKey = keyedEntries(replica)
  const appliedEntries = await run(deps.db.getSyncEntries(APPLIED_NAMESPACE))
  const sync = openPluginSync(openSyncLedger({ owner: deps, replica, applied: appliedEntries }))
  for (const plugin of locals) publishLocalPlugin(sync, plugin, replicaByKey)
  sync.ledger.retractUnlisted(localById, replicaByKey, sync.published)

  const published = flushPending(deps, PLUGINS_SYNC_NAMESPACE, sync.ledger.replicaWrites)
  if (published !== undefined) sync.changedEntries = (await published).changed
  const merged = await run(deps.db.getSyncEntries(PLUGINS_SYNC_NAMESPACE))

  for (const entry of merged) {
    if (entry.deleted === true) {
      if (!isAppliedLocal(sync.ledger, localById, entry.key)) continue

      try {
        await deps.removePlugin(entry.key)
      } catch (cause) {
        recordBlockage(sync, entry, cause)
        continue
      }
      recordRemoved(sync, entry)
      continue
    }

    const wanted = unappliedPlugin(sync.ledger, entry)
    if (wanted === undefined) continue

    const local = localById.get(entry.key)
    if (local === undefined) {
      try {
        await deps.installFromSource(wanted.value.source)
        sync.installed.push(entry.key)
        if (!wanted.value.enabled) await deps.setEnabled(entry.key, false)
      } catch (cause) {
        recordBlockage(sync, entry, cause)
        continue
      }
    } else if (local.origin === undefined) {
      continue
    } else if (local.enabled !== wanted.value.enabled) {
      await deps.setEnabled(entry.key, wanted.value.enabled)
    }
    recordApplied(sync, entry, wanted.fingerprint)
  }

  const applied = flushPending(deps, APPLIED_NAMESPACE, sync.ledger.appliedWrites)
  if (applied !== undefined) await applied
  return { status: pluginStatus(sync), changedEntries: sync.changedEntries }
}

interface PluginValue {
  readonly enabled: boolean
  readonly source: string
}

interface WantedPlugin {
  readonly value: PluginValue
  readonly fingerprint: string
}

interface PluginBlockage {
  readonly id: string
  readonly reason: string
}

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

interface PluginSync {
  readonly ledger: SyncLedger
  readonly published: Array<string>
  readonly applied: Array<string>
  readonly removed: Array<string>
  readonly installed: Array<string>
  readonly blocked: Array<PluginBlockage>
  changedEntries: ReadonlyArray<SyncEntryRecord>
}

const openPluginSync = (ledger: SyncLedger): PluginSync => ({
  ledger,
  published: [],
  applied: [],
  removed: [],
  installed: [],
  blocked: [],
  changedEntries: []
})

const unappliedPlugin = (ledger: SyncLedger, entry: SyncEntryRecord): WantedPlugin | undefined => {
  const value = pluginValue(entry.value)
  if (value === undefined) return undefined

  const fingerprint = JSON.stringify(value)
  if (ledger.applied.get(entry.key) === fingerprint) return undefined
  return { value, fingerprint }
}

const recordRemoved = (sync: PluginSync, entry: SyncEntryRecord): void => {
  sync.ledger.markRemoved(entry.key)
  sync.removed.push(entry.key)
}

const recordApplied = (sync: PluginSync, entry: SyncEntryRecord, fingerprint: string): void => {
  sync.ledger.markApplied(entry.key, () => fingerprint)
  sync.applied.push(entry.key)
}

const recordBlockage = (sync: PluginSync, entry: SyncEntryRecord, cause: unknown): void => {
  sync.blocked.push(blockage(entry.key, cause))
}

const pluginStatus = (sync: PluginSync): PluginSyncStatus => ({
  published: sync.published,
  applied: sync.applied,
  removed: sync.removed,
  installed: sync.installed,
  blocked: sync.blocked
})

const publishLocalPlugin = (
  sync: PluginSync,
  plugin: LocalPluginState,
  replicaByKey: ReadonlyMap<string, SyncEntryRecord>
): void => {
  if (plugin.origin === undefined) return

  const replicaValue = livePluginValue(replicaByKey.get(plugin.id))
  const value: PluginValue = { enabled: plugin.enabled, source: plugin.origin }
  const fingerprint = JSON.stringify(value)
  if (sync.ledger.applied.get(plugin.id) === fingerprint) return
  if (replicaGoesFirst(sync.ledger, plugin.id, replicaValue)) return

  sync.ledger.publish(plugin.id, value, () => fingerprint)
  sync.published.push(plugin.id)
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

import type { CodevisorDatabaseService } from "@codevisor/db"
import { readPluginInstallReceipt } from "@codevisor/plugins"
import {
  latestSyncTimestamp,
  nextSyncTimestamp,
  type SyncEntryRecord,
  type SyncTimestampValue
} from "@codevisor/sync"
import { Effect } from "effect"

/// Config-plane reconciliation for plugins. The "plugins" namespace holds
/// one entry per REGISTRY-SOURCED managed plugin, keyed by plugin id and
/// valued { enabled, source } — source being the repo/git origin recorded
/// in the plugin's install receipt, which any machine can fetch itself (no
/// blob ferry; the registry is the byte source). Linked dev plugins and
/// local-path installs never sync: they are machine-bound by definition.
/// Same three-way shape as the other planes, first contact deferring to
/// the fleet on collisions. Missing plugins install inline from their
/// source; failures (unmet executable requirements, network) surface as
/// blocked and retry every pass — so a plugin held on "needs ffmpeg"
/// installs by itself once the requirement appears. Tombstones uninstall.
export const PLUGINS_SYNC_NAMESPACE = "plugins"
const APPLIED_NAMESPACE = "local.plugins-applied"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

/// The install source other machines can feed to their own import flow;
/// undefined for local-path receipts (and missing receipts), which cannot
/// be fetched elsewhere and therefore never sync.
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
  /// Absent for linked/dev plugins and local-path installs (machine-only).
  readonly origin?: string | undefined
}

export interface PluginSyncDeps {
  readonly db: CodevisorDatabaseService
  readonly serverId: string
  readonly now?: () => number
  readonly listPlugins: () => Promise<ReadonlyArray<LocalPluginState>>
  /// Installs from a replicated source (registry repo or git url); throws
  /// on unmet requirements or fetch failures (surfaced as blocked).
  readonly installFromSource: (source: string) => Promise<void>
  readonly setEnabled: (pluginId: string, enabled: boolean) => Promise<void>
  readonly removePlugin: (pluginId: string) => Promise<void>
}

export interface PluginSyncStatus {
  readonly published: ReadonlyArray<string>
  readonly applied: ReadonlyArray<string>
  readonly removed: ReadonlyArray<string>
  /// Plugins installed from their source this pass.
  readonly installed: ReadonlyArray<string>
  /// Waiting on this machine (unmet requirements, unreachable source,
  /// refused uninstall). Retried on every pass.
  readonly blocked: ReadonlyArray<{ readonly id: string; readonly reason: string }>
}

export interface PluginSyncResult {
  readonly status: PluginSyncStatus
  readonly changedEntries: ReadonlyArray<SyncEntryRecord>
}

interface PluginValue {
  readonly enabled: boolean
  readonly source: string
}

const pluginValue = (value: unknown): PluginValue | undefined => {
  if (typeof value !== "object" || value === null) return undefined
  const candidate = value as Partial<PluginValue>
  if (typeof candidate.enabled !== "boolean") return undefined
  if (typeof candidate.source !== "string") return undefined
  return { enabled: candidate.enabled, source: candidate.source }
}

const reasonFrom = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

/// One reconcile pass; see the module doc for the model.
export const reconcilePlugins = async (deps: PluginSyncDeps): Promise<PluginSyncResult> => {
  const now = deps.now ?? Date.now
  const locals = await deps.listPlugins()
  const localById = new Map(locals.map((plugin) => [plugin.id, plugin]))
  const replica = await run(deps.db.getSyncEntries(PLUGINS_SYNC_NAMESPACE))
  const replicaByKey = new Map(replica.map((entry) => [entry.key, entry]))
  const appliedEntries = await run(deps.db.getSyncEntries(APPLIED_NAMESPACE))
  const appliedByKey = new Map(
    appliedEntries
      .filter((entry) => entry.deleted !== true && typeof entry.value === "string")
      .map((entry) => [entry.key, entry.value as string])
  )

  const published: Array<string> = []
  const applied: Array<string> = []
  const removed: Array<string> = []
  const installed: Array<string> = []
  const blocked: Array<{ id: string; reason: string }> = []
  const replicaWrites: Array<SyncEntryRecord> = []
  const appliedWrites: Array<SyncEntryRecord> = []
  let clock: SyncTimestampValue | undefined = latestSyncTimestamp([...replica, ...appliedEntries])
  const stamp = (): SyncTimestampValue => {
    clock = nextSyncTimestamp(deps.serverId, clock, now())
    return clock
  }

  // ── Publish: registry-sourced local plugins (edits after adoption; first
  // contact with a live replica entry adopts below instead).
  for (const plugin of locals) {
    if (plugin.origin === undefined) continue
    const entry = replicaByKey.get(plugin.id)
    const replicaValue =
      entry === undefined || entry.deleted === true ? undefined : pluginValue(entry.value)
    const value: PluginValue = { enabled: plugin.enabled, source: plugin.origin }
    const fingerprint = JSON.stringify(value)
    if (appliedByKey.get(plugin.id) === fingerprint) continue
    if (!appliedByKey.has(plugin.id) && replicaValue !== undefined) continue
    replicaWrites.push({ key: plugin.id, value, timestamp: stamp() })
    appliedWrites.push({ key: plugin.id, value: fingerprint, timestamp: stamp() })
    appliedByKey.set(plugin.id, fingerprint)
    published.push(plugin.id)
  }
  // A plugin this machine once applied that is gone was uninstalled here.
  for (const [key] of appliedByKey) {
    if (localById.has(key)) continue
    if (replicaByKey.get(key)?.deleted === true) continue
    replicaWrites.push({ key, value: null, deleted: true, timestamp: stamp() })
    appliedWrites.push({ key, value: null, deleted: true, timestamp: stamp() })
    published.push(key)
  }

  const changedEntries =
    replicaWrites.length > 0
      ? (await run(deps.db.mergeSyncEntries(PLUGINS_SYNC_NAMESPACE, replicaWrites))).changed
      : []
  const merged = await run(deps.db.getSyncEntries(PLUGINS_SYNC_NAMESPACE))

  // ── Apply. Missing plugins install inline; refusals stay blocked and
  // retry, and the applied record only lands once the machine matches.
  for (const entry of merged) {
    if (entry.deleted === true) {
      if (localById.has(entry.key) && appliedByKey.has(entry.key)) {
        try {
          await deps.removePlugin(entry.key)
        } catch (cause) {
          blocked.push({ id: entry.key, reason: reasonFrom(cause) })
          continue
        }
        appliedWrites.push({ key: entry.key, value: null, deleted: true, timestamp: stamp() })
        appliedByKey.delete(entry.key)
        removed.push(entry.key)
      }
      continue
    }
    const wanted = pluginValue(entry.value)
    if (wanted === undefined) continue
    const fingerprint = JSON.stringify(wanted)
    if (appliedByKey.get(entry.key) === fingerprint) continue
    const local = localById.get(entry.key)
    if (local === undefined) {
      try {
        await deps.installFromSource(wanted.source)
        installed.push(entry.key)
        if (!wanted.enabled) await deps.setEnabled(entry.key, false)
      } catch (cause) {
        blocked.push({ id: entry.key, reason: reasonFrom(cause) })
        continue
      }
    } else {
      // A linked/local plugin that happens to share the id stays sovereign.
      if (local.origin === undefined) continue
      if (local.enabled !== wanted.enabled) {
        await deps.setEnabled(entry.key, wanted.enabled)
      }
    }
    appliedWrites.push({ key: entry.key, value: fingerprint, timestamp: stamp() })
    appliedByKey.set(entry.key, fingerprint)
    applied.push(entry.key)
  }

  if (appliedWrites.length > 0) {
    await run(deps.db.mergeSyncEntries(APPLIED_NAMESPACE, appliedWrites))
  }
  return {
    status: { published, applied, removed, installed, blocked },
    changedEntries
  }
}

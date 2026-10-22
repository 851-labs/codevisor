import type { CodevisorDatabaseService } from "@codevisor/db"
import type { McpManager } from "@codevisor/mcp"
import {
  latestSyncTimestamp,
  nextSyncTimestamp,
  type SyncEntryRecord,
  type SyncMergeResult
} from "@codevisor/sync"
import { Effect } from "effect"

import {
  ACCOUNTS_SYNC_NAMESPACE,
  HARNESS_READINESS_NAMESPACE,
  PLUGIN_READINESS_NAMESPACE
} from "./config-sync.js"
import {
  MCP_OVERLAYS_NAMESPACE,
  MCP_READINESS_NAMESPACE,
  mcpOverlayDisableKey
} from "./mcp-fleet.js"
import { mergePending, openSyncStamps, type SyncStamps } from "./sync-ledger.js"

export const LEGACY_LOCAL_SERVER_ID = "local"

const SINGLE_WRITER_NAMESPACES: ReadonlyArray<string> = [
  MCP_READINESS_NAMESPACE,
  HARNESS_READINESS_NAMESPACE,
  PLUGIN_READINESS_NAMESPACE,
  ACCOUNTS_SYNC_NAMESPACE
]

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

export interface LegacySyncIdentityDeps {
  readonly db: CodevisorDatabaseService
  readonly serverId: string
  readonly kind: "local" | "remote"
  readonly mcp?: McpManager | undefined
}

export interface LegacySyncIdentityResult {
  readonly changed: ReadonlyArray<{
    readonly namespace: string
    readonly entries: ReadonlyArray<SyncEntryRecord>
  }>
  readonly adoptedOAuth: ReadonlyArray<string>
}

const LEGACY_OVERLAY_PREFIX = `enable|${LEGACY_LOCAL_SERVER_ID}|`

export const adoptLegacySyncIdentity = async (
  deps: LegacySyncIdentityDeps
): Promise<LegacySyncIdentityResult> => {
  if (keepsLegacyIdentity(deps)) return { changed: [], adoptedOAuth: [] }
  const changed: Array<ChangedNamespace> = []

  const overlays = await run(deps.db.getSyncEntries(MCP_OVERLAYS_NAMESPACE))
  const overlayWrites = legacyOverlayWrites(deps, overlays)
  const overlayMerge = mergePending(deps, MCP_OVERLAYS_NAMESPACE, overlayWrites)
  if (overlayMerge !== undefined) recordChanged(changed, MCP_OVERLAYS_NAMESPACE, await overlayMerge)

  for (const namespace of SINGLE_WRITER_NAMESPACES) {
    const entries = await run(deps.db.getSyncEntries(namespace))
    if (!isLiveRow(entries.find((entry) => entry.key === LEGACY_LOCAL_SERVER_ID))) continue

    const tombstone = legacyTombstone(deps, entries)
    recordChanged(changed, namespace, await run(deps.db.mergeSyncEntries(namespace, [tombstone])))
  }

  let adoptedOAuth: ReadonlyArray<string> = []
  if (deps.mcp !== undefined) {
    adoptedOAuth = await deps.mcp.adoptOAuthOwnership(LEGACY_LOCAL_SERVER_ID)
  }
  return { changed, adoptedOAuth }
}

interface ChangedNamespace {
  readonly namespace: string
  readonly entries: ReadonlyArray<SyncEntryRecord>
}

const legacyOverlayWrites = (
  deps: LegacySyncIdentityDeps,
  overlays: ReadonlyArray<SyncEntryRecord>
): Array<SyncEntryRecord> => {
  const liveKeys = new Set(
    overlays.filter((entry) => entry.deleted !== true).map((entry) => entry.key)
  )
  const stamps = openSyncStamps(deps, overlays)
  const overlayWrites: Array<SyncEntryRecord> = []
  for (const entry of overlays) adoptLegacyOverlay(deps, stamps, liveKeys, entry, overlayWrites)
  return overlayWrites
}

const adoptLegacyOverlay = (
  deps: LegacySyncIdentityDeps,
  stamps: SyncStamps,
  liveKeys: ReadonlySet<string>,
  entry: SyncEntryRecord,
  overlayWrites: Array<SyncEntryRecord>
): void => {
  if (!isLiveLegacyOverlay(entry)) return

  const name = entry.key.slice(LEGACY_OVERLAY_PREFIX.length)
  if (name.length === 0) return

  const adopted = mcpOverlayDisableKey(deps.serverId, name)
  if (!liveKeys.has(adopted)) overlayWrites.push(stamps.entry(adopted, entry.value))
  overlayWrites.push(stamps.tombstone(entry.key))
}

const keepsLegacyIdentity = (deps: LegacySyncIdentityDeps): boolean =>
  deps.kind !== "local" || deps.serverId === LEGACY_LOCAL_SERVER_ID

const isLiveLegacyOverlay = (entry: SyncEntryRecord): boolean =>
  entry.deleted !== true && entry.key.startsWith(LEGACY_OVERLAY_PREFIX)

const isLiveRow = (entry: SyncEntryRecord | undefined): boolean =>
  entry !== undefined && entry.deleted !== true

const legacyTombstone = (
  deps: LegacySyncIdentityDeps,
  entries: ReadonlyArray<SyncEntryRecord>
): SyncEntryRecord => ({
  key: LEGACY_LOCAL_SERVER_ID,
  value: null,
  deleted: true,
  timestamp: nextSyncTimestamp(deps.serverId, latestSyncTimestamp(entries), Date.now())
})

const recordChanged = (
  changed: Array<ChangedNamespace>,
  namespace: string,
  result: SyncMergeResult
): void => {
  /* v8 ignore next */
  if (result.changed.length > 0) changed.push({ namespace, entries: result.changed })
}

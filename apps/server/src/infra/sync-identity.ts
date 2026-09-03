import type { CodevisorDatabaseService } from "@codevisor/db"
import type { McpManager } from "@codevisor/mcp"
import { latestSyncTimestamp, nextSyncTimestamp, type SyncEntryRecord } from "@codevisor/sync"
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

/// App-hosted servers used to identify as the literal "local" in every sync
/// namespace: their per-machine overlay keys, their single-writer readiness
/// and roster entries, and the device id on every clock stamp they minted.
/// Two app-hosted Macs in one fleet therefore shared one identity — a
/// disable on one applied to both, both believed they owned the same OAuth
/// refresh cycle, and their readiness reports overwrote each other. Servers
/// now boot under their database's persisted machine identity; this pass
/// carries an existing fleet across: overlays written for "local" move
/// under this machine's key and the dead single-writer entries tombstone
/// so they stop shadowing the real ones.
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
  /// Only app-hosted ("local"-kind) servers ever wrote under the legacy id;
  /// a remote must never claim those entries as its own.
  readonly kind: "local" | "remote"
  /// When present, OAuth tokens this machine authorized under the legacy
  /// id are re-owned too — otherwise it would mirror its own tokens and
  /// never refresh them.
  readonly mcp?: McpManager | undefined
  readonly now?: () => number
}

export interface LegacySyncIdentityResult {
  /// Changed entries per namespace, for sync.changed publication.
  readonly changed: ReadonlyArray<{
    readonly namespace: string
    readonly entries: ReadonlyArray<SyncEntryRecord>
  }>
  /// MCP server ids whose OAuth refresh ownership moved to this machine;
  /// the caller republishes the mcps plane so mirrors learn the new owner.
  readonly adoptedOAuth: ReadonlyArray<string>
}

const LEGACY_OVERLAY_PREFIX = `enable|${LEGACY_LOCAL_SERVER_ID}|`

export const adoptLegacySyncIdentity = async (
  deps: LegacySyncIdentityDeps
): Promise<LegacySyncIdentityResult> => {
  if (deps.kind !== "local" || deps.serverId === LEGACY_LOCAL_SERVER_ID) {
    return { changed: [], adoptedOAuth: [] }
  }
  const now = deps.now ?? Date.now
  const changed: Array<{ namespace: string; entries: ReadonlyArray<SyncEntryRecord> }> = []

  const overlays = await run(deps.db.getSyncEntries(MCP_OVERLAYS_NAMESPACE))
  const liveKeys = new Set(
    overlays.filter((entry) => entry.deleted !== true).map((entry) => entry.key)
  )
  let clock = latestSyncTimestamp(overlays)
  const stamp = () => {
    clock = nextSyncTimestamp(deps.serverId, clock, now())
    return clock
  }
  const overlayWrites: Array<SyncEntryRecord> = []
  for (const entry of overlays) {
    if (entry.deleted === true || !entry.key.startsWith(LEGACY_OVERLAY_PREFIX)) continue
    const name = entry.key.slice(LEGACY_OVERLAY_PREFIX.length)
    if (name.length === 0) continue
    const adopted = mcpOverlayDisableKey(deps.serverId, name)
    // A disable already written under the real id wins; only fill gaps.
    if (!liveKeys.has(adopted)) {
      overlayWrites.push({ key: adopted, value: entry.value, timestamp: stamp() })
    }
    overlayWrites.push({ key: entry.key, value: null, deleted: true, timestamp: stamp() })
  }
  if (overlayWrites.length > 0) {
    const result = await run(deps.db.mergeSyncEntries(MCP_OVERLAYS_NAMESPACE, overlayWrites))
    // Freshly stamped writes always outrank the replica, so `changed` is
    // never empty here; the guard only keeps an empty announcement out.
    /* v8 ignore next 3 */
    if (result.changed.length > 0) {
      changed.push({ namespace: MCP_OVERLAYS_NAMESPACE, entries: result.changed })
    }
  }

  for (const namespace of SINGLE_WRITER_NAMESPACES) {
    const entries = await run(deps.db.getSyncEntries(namespace))
    const legacy = entries.find((entry) => entry.key === LEGACY_LOCAL_SERVER_ID)
    if (legacy === undefined || legacy.deleted === true) continue
    const timestamp = nextSyncTimestamp(deps.serverId, latestSyncTimestamp(entries), now())
    const result = await run(
      deps.db.mergeSyncEntries(namespace, [
        { key: LEGACY_LOCAL_SERVER_ID, value: null, deleted: true, timestamp }
      ])
    )
    /* v8 ignore next -- a fresh stamp always outranks the replica (see above). */
    if (result.changed.length > 0) changed.push({ namespace, entries: result.changed })
  }
  const adoptedOAuth =
    deps.mcp === undefined ? [] : await deps.mcp.adoptOAuthOwnership(LEGACY_LOCAL_SERVER_ID)
  return { changed, adoptedOAuth }
}

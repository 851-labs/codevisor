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
  if (deps.kind !== "local" || deps.serverId === LEGACY_LOCAL_SERVER_ID) {
    return { changed: [], adoptedOAuth: [] }
  }
  const changed: Array<{ namespace: string; entries: ReadonlyArray<SyncEntryRecord> }> = []

  const overlays = await run(deps.db.getSyncEntries(MCP_OVERLAYS_NAMESPACE))
  const liveKeys = new Set(
    overlays.filter((entry) => entry.deleted !== true).map((entry) => entry.key)
  )
  let clock = latestSyncTimestamp(overlays)
  const stamp = () => {
    clock = nextSyncTimestamp(deps.serverId, clock, Date.now())
    return clock
  }
  const overlayWrites: Array<SyncEntryRecord> = []
  for (const entry of overlays) {
    if (entry.deleted === true || !entry.key.startsWith(LEGACY_OVERLAY_PREFIX)) continue
    const name = entry.key.slice(LEGACY_OVERLAY_PREFIX.length)
    if (name.length === 0) continue
    const adopted = mcpOverlayDisableKey(deps.serverId, name)
    if (!liveKeys.has(adopted)) {
      overlayWrites.push({ key: adopted, value: entry.value, timestamp: stamp() })
    }
    overlayWrites.push({ key: entry.key, value: null, deleted: true, timestamp: stamp() })
  }
  if (overlayWrites.length > 0) {
    const result = await run(deps.db.mergeSyncEntries(MCP_OVERLAYS_NAMESPACE, overlayWrites))
    /* v8 ignore next 3 */
    if (result.changed.length > 0) {
      changed.push({ namespace: MCP_OVERLAYS_NAMESPACE, entries: result.changed })
    }
  }

  for (const namespace of SINGLE_WRITER_NAMESPACES) {
    const entries = await run(deps.db.getSyncEntries(namespace))
    const legacy = entries.find((entry) => entry.key === LEGACY_LOCAL_SERVER_ID)
    if (legacy === undefined || legacy.deleted === true) continue
    const timestamp = nextSyncTimestamp(deps.serverId, latestSyncTimestamp(entries), Date.now())
    const result = await run(
      deps.db.mergeSyncEntries(namespace, [
        { key: LEGACY_LOCAL_SERVER_ID, value: null, deleted: true, timestamp }
      ])
    )
    /* v8 ignore next */
    if (result.changed.length > 0) changed.push({ namespace, entries: result.changed })
  }
  const adoptedOAuth =
    deps.mcp === undefined ? [] : await deps.mcp.adoptOAuthOwnership(LEGACY_LOCAL_SERVER_ID)
  return { changed, adoptedOAuth }
}

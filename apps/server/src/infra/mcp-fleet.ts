import type { CodevisorDatabaseService } from "@codevisor/db"
import type { McpManager } from "@codevisor/mcp"
import type { SyncEntryRecord } from "@codevisor/sync"
import { Effect } from "effect"

import { field } from "../unknown-values.js"
import { publishMachineReadiness } from "./config-sync.js"

export const MCP_READINESS_NAMESPACE = "mcp-readiness"
export const MCP_OVERLAYS_NAMESPACE = "mcp-overlays"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

export const mcpOverlayDisableKey = (serverId: string, name: string): string =>
  `enable|${serverId}|${name}`

export interface McpOverlays {
  readonly disabledHere: ReadonlySet<string>
}

export const readMcpOverlays = async (
  db: CodevisorDatabaseService,
  serverId: string
): Promise<McpOverlays> => {
  const entries = await run(db.getSyncEntries(MCP_OVERLAYS_NAMESPACE))
  const disabledHere = new Set<string>()
  for (const entry of entries) {
    if (entry.deleted === true || !entry.key.startsWith("enable|")) continue
    const rest = entry.key.slice("enable|".length)
    const split = rest.indexOf("|")
    if (split <= 0) continue
    const name = rest.slice(split + 1)
    if (
      rest.slice(0, split) === serverId &&
      field(entry.value, "enabled") === false &&
      name.length > 0
    ) {
      disabledHere.add(name)
    }
  }
  return { disabledHere }
}

export type McpReadinessState = "ready" | "connecting" | "idle" | "blocked" | "disabled"

export interface McpReadinessEntry {
  readonly name: string
  readonly state: McpReadinessState
  readonly reason?: string | undefined
  readonly code?: string | undefined
  readonly toolCount?: number | undefined
}

const BLOCKED_REASONS: Readonly<Record<string, string>> = {
  needsSetup: "Needs setup on this machine",
  unavailable: "Unavailable on this machine",
  needsAuthorization: "Needs authorization",
  expired: "Authorization expired",
  error: "Connection error"
}

export const mcpReadiness = (
  server: {
    readonly name: string
    readonly enabled: boolean
    readonly connectionState: string
    readonly detail?: string | undefined
    readonly toolCount?: number | undefined
  },
  overlays: McpOverlays
): McpReadinessEntry => {
  if (overlays.disabledHere.has(server.name)) {
    return { name: server.name, state: "disabled", reason: "Disabled on this machine" }
  }
  if (!server.enabled) {
    return { name: server.name, state: "disabled", reason: "Disabled for the whole fleet" }
  }
  if (server.connectionState === "connected") {
    return {
      name: server.name,
      state: "ready",
      ...(server.toolCount === undefined ? {} : { toolCount: server.toolCount })
    }
  }
  if (server.connectionState === "connecting") return { name: server.name, state: "connecting" }
  if (server.connectionState === "disconnected") return { name: server.name, state: "idle" }
  return {
    name: server.name,
    state: "blocked",
    code: server.connectionState,
    reason: server.detail ?? BLOCKED_REASONS[server.connectionState] ?? server.connectionState
  }
}

export interface McpReadinessDeps {
  readonly db: CodevisorDatabaseService
  readonly mcp: McpManager
  readonly serverId: string
}

export const publishMcpReadiness = async (
  deps: McpReadinessDeps
): Promise<{
  readonly changedEntries: ReadonlyArray<SyncEntryRecord>
}> => {
  const overlays = await readMcpOverlays(deps.db, deps.serverId)
  const servers = (await deps.mcp.list())
    .map((server) => mcpReadiness(server, overlays))
    .toSorted((a, b) => a.name.localeCompare(b.name))
  return publishMachineReadiness({
    db: deps.db,
    namespace: MCP_READINESS_NAMESPACE,
    serverId: deps.serverId,
    value: { servers }
  })
}

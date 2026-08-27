import type { CodevisorDatabaseService } from "@codevisor/db"
import type { McpManager } from "@codevisor/mcp"
import type { SyncEntryRecord } from "@codevisor/sync"
import { Effect } from "effect"
import { publishMachineReadiness } from "./config-sync.js"

/// Phase 17: the MCP plane's per-machine data. Two namespaces:
///
/// "mcp-readiness" — what each MCP actually looks like ON each machine
/// (ready, blocked and why, disabled here, pinned elsewhere). Single-writer:
/// every machine publishes only its own entry, keyed by its server id, so
/// readiness can never conflict. Derived from the manager's live connection
/// state — a synced definition that cannot work somewhere (missing command,
/// ungranted OS permission) finally has a fleet-visible reason.
///
/// "mcp-overlays" — the one per-machine knob the fleet definition
/// deliberately does not carry: disable one MCP on one machine without
/// touching the fleet. Plain LWW entries any client writes via the generic
/// sync surface:
///   "enable|<serverId>|<name>"  → { enabled: false }   delete to restore
/// The name sits LAST in the key, so names may contain the delimiter;
/// server ids (uuid/hostname-shaped) must not.
export const MCP_READINESS_NAMESPACE = "mcp-readiness"
export const MCP_OVERLAYS_NAMESPACE = "mcp-overlays"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

export const mcpOverlayDisableKey = (serverId: string, name: string): string =>
  `enable|${serverId}|${name}`

/// The overlays as they apply to THIS machine.
export interface McpOverlays {
  /// Names switched off here by a per-machine enable overlay.
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
    const value = entry.value as { readonly enabled?: unknown } | null
    if (rest.slice(0, split) === serverId && value?.enabled === false && name.length > 0) {
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
}

const BLOCKED_REASONS: Readonly<Record<string, string>> = {
  needsSetup: "Needs setup on this machine",
  unavailable: "Unavailable on this machine",
  needsAuthorization: "Needs authorization",
  expired: "Authorization expired",
  error: "Connection error"
}

/// One server's readiness ON this machine. The per-machine overlay outranks
/// live state, and each "disabled" carries its provenance — the reason
/// distinguishes a machine opt-out from a fleet-wide disable.
export const mcpReadiness = (
  server: {
    readonly name: string
    readonly enabled: boolean
    readonly connectionState: string
    readonly detail?: string | undefined
  },
  overlays: McpOverlays
): McpReadinessEntry => {
  if (overlays.disabledHere.has(server.name)) {
    return { name: server.name, state: "disabled", reason: "Disabled on this machine" }
  }
  if (!server.enabled) {
    return { name: server.name, state: "disabled", reason: "Disabled for the whole fleet" }
  }
  if (server.connectionState === "connected") return { name: server.name, state: "ready" }
  if (server.connectionState === "connecting") return { name: server.name, state: "connecting" }
  if (server.connectionState === "disconnected") return { name: server.name, state: "idle" }
  return {
    name: server.name,
    state: "blocked",
    reason: server.detail ?? BLOCKED_REASONS[server.connectionState] ?? server.connectionState
  }
}

export interface McpReadinessDeps {
  readonly db: CodevisorDatabaseService
  readonly mcp: McpManager
  readonly serverId: string
}

/// Publishes this machine's MCP readiness under its own machine key —
/// single-writer, change-detected, so a settled machine republishes
/// nothing. Built-in providers (computer use, browser use) are included
/// deliberately: they are the most machine-specific MCPs of all.
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

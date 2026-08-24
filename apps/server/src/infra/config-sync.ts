import type { CodevisorDatabaseService } from "@codevisor/db"
import type { McpManager } from "@codevisor/mcp"
import {
  latestSyncTimestamp,
  nextSyncTimestamp,
  type SyncEntryRecord,
  type SyncTimestampValue
} from "@codevisor/sync"
import { Effect } from "effect"

/// Config-plane reconciliation for MCP definitions and the harness-account
/// roster. Same three-way shape as skills-sync: a private dot-named
/// "applied" namespace records what this machine last published or applied,
/// distinguishing a local edit from replica lag. Secrets NEVER travel:
/// synced MCP values carry the definition (transport, url/command, args,
/// auth TYPE) — env, headers, tokens, and ciphers stay on each machine.
export const MCPS_SYNC_NAMESPACE = "mcps"
const MCPS_APPLIED_NAMESPACE = "local.mcps-applied"
export const ACCOUNTS_SYNC_NAMESPACE = "harness-accounts"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

export interface McpSyncStatus {
  readonly published: ReadonlyArray<string>
  readonly applied: ReadonlyArray<string>
  readonly removed: ReadonlyArray<string>
}

interface SyncedMcpValue {
  readonly name: string
  readonly transport: "http" | "stdio"
  readonly url?: string | undefined
  readonly command?: string | undefined
  readonly args: ReadonlyArray<string>
  readonly enabled: boolean
  readonly authType: "none" | "bearer" | "oauth"
  readonly oauthScope?: string | undefined
}

interface McpLike {
  readonly id: string
  readonly name: string
  readonly kind: string
  readonly transport: "http" | "stdio"
  readonly url?: string | undefined
  readonly command?: string | undefined
  readonly args: ReadonlyArray<string>
  readonly enabled: boolean
  readonly authType: "none" | "bearer" | "oauth"
  readonly oauthScope?: string | undefined
}

const syncedValue = (server: McpLike): SyncedMcpValue => ({
  name: server.name,
  transport: server.transport,
  ...(server.url === undefined ? {} : { url: server.url }),
  ...(server.command === undefined ? {} : { command: server.command }),
  args: [...server.args],
  enabled: server.enabled,
  authType: server.authType,
  ...(server.oauthScope === undefined ? {} : { oauthScope: server.oauthScope })
})

const fingerprint = (value: SyncedMcpValue): string => JSON.stringify(value)

const parseSyncedValue = (value: unknown): SyncedMcpValue | undefined => {
  if (typeof value !== "object" || value === null) return undefined
  const candidate = value as Partial<SyncedMcpValue>
  if (typeof candidate.name !== "string") return undefined
  if (candidate.transport !== "http" && candidate.transport !== "stdio") return undefined
  if (typeof candidate.enabled !== "boolean") return undefined
  if (
    candidate.authType !== "none" &&
    candidate.authType !== "bearer" &&
    candidate.authType !== "oauth"
  ) {
    return undefined
  }
  return {
    name: candidate.name,
    transport: candidate.transport,
    ...(typeof candidate.url === "string" ? { url: candidate.url } : {}),
    ...(typeof candidate.command === "string" ? { command: candidate.command } : {}),
    args: Array.isArray(candidate.args)
      ? candidate.args.filter((item): item is string => typeof item === "string")
      : [],
    enabled: candidate.enabled,
    authType: candidate.authType,
    ...(typeof candidate.oauthScope === "string" ? { oauthScope: candidate.oauthScope } : {})
  }
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

/// Reconciles this machine's MANAGED MCP definitions against the replica.
/// Keys are the definition names — the one identity that survives each
/// machine minting its own record ids.
export const reconcileMcps = async (deps: McpSyncDeps): Promise<McpSyncResult> => {
  const now = deps.now ?? Date.now
  const locals = (await deps.mcp.list()).filter((server) => server.kind === "managed")
  const localByName = new Map(locals.map((server) => [server.name, server]))
  const replica = await run(deps.db.getSyncEntries(MCPS_SYNC_NAMESPACE))
  const replicaByKey = new Map(replica.map((entry) => [entry.key, entry]))
  const appliedEntries = await run(deps.db.getSyncEntries(MCPS_APPLIED_NAMESPACE))
  const appliedByKey = new Map(
    appliedEntries
      .filter((entry) => entry.deleted !== true && typeof entry.value === "string")
      .map((entry) => [entry.key, entry.value as string])
  )

  const published: Array<string> = []
  const applied: Array<string> = []
  const removed: Array<string> = []
  const replicaWrites: Array<SyncEntryRecord> = []
  const appliedWrites: Array<SyncEntryRecord> = []
  let clock: SyncTimestampValue | undefined = latestSyncTimestamp([...replica, ...appliedEntries])
  const stamp = (): SyncTimestampValue => {
    clock = nextSyncTimestamp(deps.serverId, clock, now())
    return clock
  }

  // Local creations and edits publish.
  for (const [name, server] of localByName) {
    const value = syncedValue(server)
    if (appliedByKey.get(name) === fingerprint(value)) continue
    replicaWrites.push({ key: name, value, timestamp: stamp() })
    appliedWrites.push({ key: name, value: fingerprint(value), timestamp: stamp() })
    appliedByKey.set(name, fingerprint(value))
    published.push(name)
  }
  // Local deletions publish tombstones.
  for (const [name] of appliedByKey) {
    if (localByName.has(name)) continue
    if (replicaByKey.get(name)?.deleted === true) continue
    replicaWrites.push({ key: name, value: null, deleted: true, timestamp: stamp() })
    appliedWrites.push({ key: name, value: null, deleted: true, timestamp: stamp() })
    published.push(name)
  }

  const changedEntries =
    replicaWrites.length > 0
      ? (await run(deps.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, replicaWrites))).changed
      : []
  const merged = await run(deps.db.getSyncEntries(MCPS_SYNC_NAMESPACE))

  // Replica entries apply into the manager.
  for (const entry of merged) {
    const name = entry.key
    const local = localByName.get(name)
    if (entry.deleted === true) {
      if (local !== undefined && appliedByKey.get(name) === fingerprint(syncedValue(local))) {
        await deps.mcp.remove(local.id)
        appliedWrites.push({ key: name, value: null, deleted: true, timestamp: stamp() })
        appliedByKey.delete(name)
        removed.push(name)
      }
      continue
    }
    const wanted = parseSyncedValue(entry.value)
    if (wanted === undefined) continue
    const wantedFingerprint = fingerprint(wanted)
    // The publish loop above already recorded every local definition, so a
    // matching applied fingerprint covers "already ours" too.
    if (appliedByKey.get(name) === wantedFingerprint) continue
    if (local === undefined) {
      await deps.mcp.create({
        name: wanted.name,
        transport: wanted.transport,
        ...(wanted.url === undefined ? {} : { url: wanted.url }),
        ...(wanted.command === undefined ? {} : { command: wanted.command }),
        args: wanted.args,
        enabled: wanted.enabled,
        authType: wanted.authType,
        ...(wanted.oauthScope === undefined ? {} : { oauthScope: wanted.oauthScope })
      })
    } else {
      // Definition fields only: env/headers/tokens stay untouched, so a
      // machine's local secrets survive replica updates.
      await deps.mcp.update(local.id, {
        name: wanted.name,
        enabled: wanted.enabled,
        ...(wanted.url === undefined ? {} : { url: wanted.url }),
        ...(wanted.command === undefined ? {} : { command: wanted.command }),
        args: wanted.args,
        authType: wanted.authType,
        ...(wanted.oauthScope === undefined ? {} : { oauthScope: wanted.oauthScope })
      })
    }
    appliedWrites.push({ key: name, value: wantedFingerprint, timestamp: stamp() })
    appliedByKey.set(name, wantedFingerprint)
    applied.push(name)
  }

  if (appliedWrites.length > 0) {
    await run(deps.db.mergeSyncEntries(MCPS_APPLIED_NAMESPACE, appliedWrites))
  }
  return { status: { published, applied, removed }, changedEntries }
}

export interface AccountsRosterDeps {
  readonly db: CodevisorDatabaseService
  readonly harnessIds: ReadonlyArray<string>
  readonly serverId: string
  readonly now?: () => number
}

/// Publishes this machine's harness-account roster (metadata ONLY — no
/// credential material) under its own machine key. Each machine writes only
/// its own entry: single-writer, so the roster can never conflict. Purely
/// informational groundwork for fleet-wide account views.
export const publishAccountsRoster = async (
  deps: AccountsRosterDeps
): Promise<{ readonly changedEntries: ReadonlyArray<SyncEntryRecord> }> => {
  const now = deps.now ?? Date.now
  const accounts: Array<{
    readonly harnessId: string
    readonly label: string
    readonly email?: string | undefined
    readonly authState: string
    readonly profileKind: string
  }> = []
  for (const harnessId of deps.harnessIds) {
    for (const account of await run(deps.db.listHarnessAccounts(harnessId))) {
      accounts.push({
        harnessId,
        label: account.label,
        ...(account.email === undefined ? {} : { email: account.email }),
        authState: account.authState,
        profileKind: account.profileKind
      })
    }
  }
  const replica = await run(deps.db.getSyncEntries(ACCOUNTS_SYNC_NAMESPACE))
  const existing = replica.find((entry) => entry.key === deps.serverId)
  const value = { accounts }
  if (existing !== undefined && JSON.stringify(existing.value) === JSON.stringify(value)) {
    return { changedEntries: [] }
  }
  const timestamp = nextSyncTimestamp(deps.serverId, latestSyncTimestamp(replica), now())
  const result = await run(
    deps.db.mergeSyncEntries(ACCOUNTS_SYNC_NAMESPACE, [{ key: deps.serverId, value, timestamp }])
  )
  return { changedEntries: result.changed }
}

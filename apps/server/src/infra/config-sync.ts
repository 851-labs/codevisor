import type { CodevisorDatabaseService } from "@codevisor/db"
import type { McpManager } from "@codevisor/mcp"
import {
  freeSyncKey,
  latestSyncTimestamp,
  nextSyncTimestamp,
  type SyncEntryRecord,
  type SyncTimestampValue
} from "@codevisor/sync"
import { Effect } from "effect"

import { appliedValuesByKey } from "./applied-values.js"

export const MCPS_SYNC_NAMESPACE = "mcps"
const MCPS_APPLIED_NAMESPACE = "local.mcps-applied"
export const ACCOUNTS_SYNC_NAMESPACE = "harness-accounts"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

export interface McpSyncStatus {
  readonly published: ReadonlyArray<string>
  readonly applied: ReadonlyArray<string>
  readonly removed: ReadonlyArray<string>
  readonly renamed: ReadonlyArray<{ readonly from: string; readonly to: string }>
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
  readonly bearerToken?: string | undefined
  readonly headers?: Readonly<Record<string, string>> | undefined
  readonly env?: Readonly<Record<string, string>> | undefined
  readonly oauth?: SyncedOAuthEnvelope | undefined
}

interface SyncedOAuthEnvelope {
  readonly owner: string
  readonly rotatedAtMs: number
  readonly material: string
}

const oauthEnvelope = (value: unknown): SyncedOAuthEnvelope | undefined => {
  if (typeof value !== "object" || value === null) return undefined
  const candidate = value as Partial<SyncedOAuthEnvelope>
  if (typeof candidate.owner !== "string") return undefined
  if (typeof candidate.rotatedAtMs !== "number") return undefined
  if (typeof candidate.material !== "string") return undefined
  return {
    owner: candidate.owner,
    rotatedAtMs: candidate.rotatedAtMs,
    material: candidate.material
  }
}

interface StaticMcpSecrets {
  readonly bearerToken?: string | undefined
  readonly headers?: Readonly<Record<string, string>> | undefined
  readonly env?: Readonly<Record<string, string>> | undefined
}

const sortedRecord = (
  value: Readonly<Record<string, string>> | undefined
): Record<string, string> | undefined => {
  if (value === undefined || Object.keys(value).length === 0) return undefined
  return Object.fromEntries(Object.entries(value).toSorted(([a], [b]) => a.localeCompare(b)))
}

const stringRecord = (value: unknown): Record<string, string> | undefined => {
  if (typeof value !== "object" || value === null) return undefined
  return sortedRecord(
    Object.fromEntries(
      Object.entries(value).filter((pair): pair is [string, string] => typeof pair[1] === "string")
    )
  )
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
  readonly headerNames?: ReadonlyArray<string> | undefined
  readonly environmentNames?: ReadonlyArray<string> | undefined
}

const syncedValue = (server: McpLike, secrets: StaticMcpSecrets): SyncedMcpValue => {
  const headers = sortedRecord(secrets.headers)
  const env = sortedRecord(secrets.env)
  return {
    name: server.name,
    transport: server.transport,
    ...(server.url === undefined ? {} : { url: server.url }),
    ...(server.command === undefined ? {} : { command: server.command }),
    args: [...server.args],
    enabled: server.enabled,
    authType: server.authType,
    ...(server.oauthScope === undefined ? {} : { oauthScope: server.oauthScope }),
    ...(secrets.bearerToken === undefined ? {} : { bearerToken: secrets.bearerToken }),
    ...(headers === undefined ? {} : { headers }),
    ...(env === undefined ? {} : { env })
  }
}

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
  const isHttp = candidate.transport === "http"
  const headers = isHttp ? stringRecord(candidate.headers) : undefined
  const env = isHttp ? undefined : stringRecord(candidate.env)
  const oauth =
    isHttp && candidate.authType === "oauth" ? oauthEnvelope(candidate.oauth) : undefined
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
    ...(typeof candidate.oauthScope === "string" ? { oauthScope: candidate.oauthScope } : {}),
    ...(isHttp && typeof candidate.bearerToken === "string" && candidate.bearerToken !== ""
      ? { bearerToken: candidate.bearerToken }
      : {}),
    ...(headers === undefined ? {} : { headers }),
    ...(env === undefined ? {} : { env }),
    ...(oauth === undefined ? {} : { oauth })
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

export const reconcileMcps = async (deps: McpSyncDeps): Promise<McpSyncResult> => {
  const now = deps.now ?? Date.now
  const locals = (await deps.mcp.list()).filter((server) => server.kind === "managed")
  const localByName = new Map(locals.map((server) => [server.name, server]))
  const replica = await run(deps.db.getSyncEntries(MCPS_SYNC_NAMESPACE))
  const replicaByKey = new Map(replica.map((entry) => [entry.key, entry]))
  const appliedEntries = await run(deps.db.getSyncEntries(MCPS_APPLIED_NAMESPACE))
  const appliedByKey = appliedValuesByKey(appliedEntries)

  const published: Array<string> = []
  const applied: Array<string> = []
  const removed: Array<string> = []
  const renamed: Array<{ from: string; to: string }> = []
  const replicaWrites: Array<SyncEntryRecord> = []
  const appliedWrites: Array<SyncEntryRecord> = []
  let clock: SyncTimestampValue | undefined = latestSyncTimestamp([...replica, ...appliedEntries])
  const stamp = (): SyncTimestampValue => {
    clock = nextSyncTimestamp(deps.serverId, clock, now())
    return clock
  }

  for (const [name, server] of Array.from(localByName)) {
    const existing = replicaByKey.get(name)
    const wanted = existing?.deleted === true ? undefined : parseSyncedValue(existing?.value)
    const oauthState =
      server.authType === "oauth" ? await deps.mcp.oauthSyncState(server.id) : undefined
    const ownedOAuth =
      oauthState !== undefined && oauthState.owner === deps.serverId ? oauthState : undefined
    const envelope = ownedOAuth ?? wanted?.oauth
    let value: SyncedMcpValue = {
      ...syncedValue(server, await deps.mcp.staticSecrets(server.id)),
      ...(envelope === undefined ? {} : { oauth: envelope })
    }
    if (appliedByKey.get(name) === fingerprint(value)) continue
    let key = name
    if (!appliedByKey.has(name) && wanted !== undefined) {
      if (fingerprint(wanted) === fingerprint(value)) {
        appliedWrites.push({ key: name, value: fingerprint(value), timestamp: stamp() })
        appliedByKey.set(name, fingerprint(value))
        continue
      }
      key = freeSyncKey(
        name,
        (candidate) => localByName.has(candidate) || replicaByKey.has(candidate)
      )
      await deps.mcp.update(server.id, { name: key })
      localByName.delete(name)
      localByName.set(key, { ...server, name: key })
      value = { ...value, name: key }
      renamed.push({ from: name, to: key })
    }
    replicaWrites.push({ key, value, timestamp: stamp() })
    appliedWrites.push({ key, value: fingerprint(value), timestamp: stamp() })
    appliedByKey.set(key, fingerprint(value))
    published.push(key)
  }
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

  for (const entry of merged) {
    const name = entry.key
    const local = localByName.get(name)
    if (entry.deleted === true) {
      if (
        local !== undefined &&
        appliedByKey.get(name) ===
          fingerprint(syncedValue(local, await deps.mcp.staticSecrets(local.id)))
      ) {
        await deps.mcp.remove(local.id)
        appliedWrites.push({ key: name, value: null, deleted: true, timestamp: stamp() })
        appliedByKey.delete(name)
        removed.push(name)
      }
      continue
    }
    const wanted = parseSyncedValue(entry.value)
    if (wanted === undefined) continue
    if (wanted.oauth !== undefined && wanted.oauth.owner !== deps.serverId) {
      const holder = localByName.get(name)
      if (holder !== undefined) {
        await deps.mcp.importOAuthMaterial(holder.id, wanted.oauth)
      }
    }
    const wantedFingerprint = fingerprint(wanted)
    if (appliedByKey.get(name) === wantedFingerprint) continue
    if (local === undefined) {
      const created = await deps.mcp.create({
        name: wanted.name,
        transport: wanted.transport,
        ...(wanted.url === undefined ? {} : { url: wanted.url }),
        ...(wanted.command === undefined ? {} : { command: wanted.command }),
        args: wanted.args,
        enabled: wanted.enabled,
        authType: wanted.authType,
        ...(wanted.oauthScope === undefined ? {} : { oauthScope: wanted.oauthScope }),
        ...(wanted.bearerToken === undefined ? {} : { bearerToken: wanted.bearerToken }),
        ...(wanted.headers === undefined ? {} : { headers: wanted.headers }),
        ...(wanted.env === undefined ? {} : { env: wanted.env })
      })
      if (wanted.oauth !== undefined && wanted.oauth.owner !== deps.serverId) {
        await deps.mcp.importOAuthMaterial(created.id, wanted.oauth)
      }
    } else {
      const wantedHeaders = wanted.headers ?? {}
      const wantedEnv = wanted.env ?? {}
      await deps.mcp.update(local.id, {
        name: wanted.name,
        enabled: wanted.enabled,
        ...(wanted.url === undefined ? {} : { url: wanted.url }),
        ...(wanted.command === undefined ? {} : { command: wanted.command }),
        args: wanted.args,
        authType: wanted.authType,
        ...(wanted.oauthScope === undefined ? {} : { oauthScope: wanted.oauthScope }),
        ...(wanted.transport === "http"
          ? {
              bearerToken: wanted.bearerToken ?? "",
              ...(wanted.headers === undefined ? {} : { headers: wanted.headers }),
              /* v8 ignore next 2 */
              removeHeaders: (local.headerNames ?? []).filter(
                (header) => wantedHeaders[header] === undefined
              )
            }
          : {
              ...(wanted.env === undefined ? {} : { env: wanted.env }),
              /* v8 ignore next 2 */
              removeEnv: (local.environmentNames ?? []).filter(
                (variable) => wantedEnv[variable] === undefined
              )
            })
      })
    }
    appliedWrites.push({ key: name, value: wantedFingerprint, timestamp: stamp() })
    appliedByKey.set(name, wantedFingerprint)
    applied.push(name)
  }

  if (appliedWrites.length > 0) {
    await run(deps.db.mergeSyncEntries(MCPS_APPLIED_NAMESPACE, appliedWrites))
  }
  return { status: { published, applied, removed, renamed }, changedEntries }
}

export interface AccountsRosterDeps {
  readonly db: CodevisorDatabaseService
  readonly harnessIds: ReadonlyArray<string>
  readonly serverId: string
  readonly now?: () => number
}

export const HARNESS_READINESS_NAMESPACE = "harness-readiness"

export interface HarnessReadinessRow {
  readonly id: string
  readonly name: string
  readonly symbolName: string
  readonly installed?: boolean
  readonly authRequired: boolean
  readonly state:
    | "ready"
    | "signInRequired"
    | "notInstalled"
    | "disabled"
    | "blocked"
    | "installing"
    | "uninstalling"
  readonly reason?: string | undefined
  readonly version?: string
}

export const publishMachineReadiness = async (deps: {
  readonly db: CodevisorDatabaseService
  readonly namespace: string
  readonly serverId: string
  readonly value: object
  readonly now?: () => number
  readonly answers?: ReadonlyArray<SyncEntryRecord>
}): Promise<{ readonly changedEntries: ReadonlyArray<SyncEntryRecord> }> => {
  const now = deps.now ?? Date.now
  const answers = deps.answers ?? []
  const replica = await run(deps.db.getSyncEntries(deps.namespace))
  const existing = replica.find((entry) => entry.key === deps.serverId)
  if (
    answers.length === 0 &&
    existing !== undefined &&
    JSON.stringify(existing.value) === JSON.stringify(deps.value)
  ) {
    return { changedEntries: [] }
  }
  const timestamp = nextSyncTimestamp(
    deps.serverId,
    latestSyncTimestamp([...replica, ...answers]),
    now()
  )
  const result = await run(
    deps.db.mergeSyncEntries(deps.namespace, [{ key: deps.serverId, value: deps.value, timestamp }])
  )
  return { changedEntries: result.changed }
}

export const PLUGIN_READINESS_NAMESPACE = "plugin-readiness"

export interface PluginReadinessRow {
  readonly id: string
  readonly state: "ready" | "disabled" | "notInstalled" | "blocked" | "machineOnly"
  readonly reason?: string | undefined
}

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

import type { CreateMcpServerRequest, UpdateMcpServerRequest } from "@codevisor/api"
import type { McpCredentialReference } from "@codevisor/mcp"

import { field } from "../unknown-values.js"

export interface SyncedMcpValue {
  readonly name: string
  readonly catalogId?: string | undefined
  readonly catalogVersion?: string | undefined
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
  readonly oauthCredential?: McpCredentialReference | null | undefined
}

export interface StaticMcpSecrets {
  readonly bearerToken?: string | undefined
  readonly headers?: Readonly<Record<string, string>> | undefined
  readonly env?: Readonly<Record<string, string>> | undefined
}

export interface McpLike {
  readonly id: string
  readonly name: string
  readonly catalogId?: string | undefined
  readonly catalogVersion?: string | undefined
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

export type HeldCredential = McpCredentialReference | null | undefined

export const withCredential = (
  value: SyncedMcpValue,
  credential: HeldCredential
): SyncedMcpValue => ({
  ...value,
  ...(credential === undefined ? {} : { oauthCredential: credential })
})

export const withHeldCredential = (
  received: SyncedMcpValue,
  held: HeldCredential
): SyncedMcpValue => {
  if (received.oauthCredential === undefined && held !== undefined && held !== null) {
    return { ...received, oauthCredential: held }
  }
  return received
}

export const mcpCreation = (wanted: SyncedMcpValue): CreateMcpServerRequest => ({
  name: wanted.name,
  ...(wanted.catalogId === undefined ? {} : { catalogId: wanted.catalogId }),
  ...(wanted.catalogVersion === undefined ? {} : { catalogVersion: wanted.catalogVersion }),
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

export const mcpUpdate = (local: McpLike, wanted: SyncedMcpValue): UpdateMcpServerRequest => ({
  name: wanted.name,
  enabled: wanted.enabled,
  ...(wanted.url === undefined ? {} : { url: wanted.url }),
  ...(wanted.command === undefined ? {} : { command: wanted.command }),
  args: wanted.args,
  authType: wanted.authType,
  ...(wanted.oauthScope === undefined ? {} : { oauthScope: wanted.oauthScope }),
  ...(wanted.transport === "http"
    ? httpSecretsUpdate(local, wanted)
    : stdioSecretsUpdate(local, wanted))
})

export const syncedValue = (server: McpLike, secrets: StaticMcpSecrets): SyncedMcpValue => {
  const headers = sortedRecord(secrets.headers)
  const env = sortedRecord(secrets.env)
  return {
    name: server.name,
    ...catalogOf(server),
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

export const fingerprint = (value: SyncedMcpValue): string => JSON.stringify(value)

export const withLegacyOAuth = (value: SyncedMcpValue, replicated: unknown): object => {
  const legacy = field(replicated, "oauth")
  return legacy === undefined ? value : { ...value, oauth: legacy }
}

export const parseSyncedValue = (value: unknown): SyncedMcpValue | undefined => {
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
  const credential =
    isHttp && candidate.authType === "oauth"
      ? oauthCredential(candidate.oauthCredential)
      : undefined
  return {
    name: candidate.name,
    ...catalogOf(candidate),
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
    ...(credential === undefined ? {} : { oauthCredential: credential })
  }
}

const catalogOf = (value: {
  readonly catalogId?: unknown
  readonly catalogVersion?: unknown
}): { readonly catalogId?: string; readonly catalogVersion?: string } => ({
  ...(typeof value.catalogId === "string" ? { catalogId: value.catalogId } : {}),
  ...(typeof value.catalogVersion === "string" ? { catalogVersion: value.catalogVersion } : {})
})

const httpSecretsUpdate = (local: McpLike, wanted: SyncedMcpValue): UpdateMcpServerRequest => {
  const wantedHeaders = wanted.headers ?? {}
  return {
    bearerToken: wanted.bearerToken ?? "",
    ...(wanted.headers === undefined ? {} : { headers: wanted.headers }),
    /* v8 ignore next 2 */
    removeHeaders: (local.headerNames ?? []).filter((header) => wantedHeaders[header] === undefined)
  }
}

const stdioSecretsUpdate = (local: McpLike, wanted: SyncedMcpValue): UpdateMcpServerRequest => {
  const wantedEnv = wanted.env ?? {}
  return {
    ...(wanted.env === undefined ? {} : { env: wanted.env }),
    /* v8 ignore next 2 */
    removeEnv: (local.environmentNames ?? []).filter(
      (variable) => wantedEnv[variable] === undefined
    )
  }
}

const oauthCredential = (value: unknown): McpCredentialReference | null | undefined => {
  if (value === null) return null
  if (typeof value !== "object") return undefined
  const candidate = value as Partial<McpCredentialReference>
  if (typeof candidate.id !== "string" || !/^[a-zA-Z0-9_-]{16,100}$/.test(candidate.id))
    return undefined
  if (typeof candidate.key !== "string" || !/^[a-zA-Z0-9_-]{43}$/.test(candidate.key))
    return undefined
  return { id: candidate.id, key: candidate.key }
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

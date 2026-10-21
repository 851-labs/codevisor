import { refreshAuthorization } from "@modelcontextprotocol/sdk/client/auth.js"
import {
  OAuthError,
  ServerError,
  TemporarilyUnavailableError,
  TooManyRequestsError
} from "@modelcontextprotocol/sdk/server/auth/errors.js"
import {
  type OAuthClientInformationMixed,
  OAuthClientInformationFullSchema,
  OAuthClientInformationSchema,
  OAuthMetadataSchema,
  type OAuthTokens,
  OpenIdProviderDiscoveryMetadataSchema
} from "@modelcontextprotocol/sdk/shared/auth.js"
import { z } from "zod"

import { isRecord } from "./mcp-guards.js"

export interface McpCredentialReference {
  readonly id: string
  readonly key: string
}

export interface McpTokenBundle {
  readonly harnessId: "mcp"
  readonly subject: string
  readonly accessToken: string
  readonly refreshToken?: string
  readonly expiresAt: number
  readonly scopes?: ReadonlyArray<string>
  readonly credential?: Readonly<Record<string, unknown>>
  readonly ownership: "managed"
}

export interface McpOAuthVault {
  readonly create: (bundle: McpTokenBundle) => Promise<McpCredentialReference>
  readonly token: (
    reference: McpCredentialReference,
    rejectedAccessToken?: string
  ) => Promise<{ readonly accessToken: string; readonly expiresAt: number }>
  readonly revoke: (reference: McpCredentialReference) => Promise<void>
}

export class McpRefreshRejected extends Error {
  constructor(readonly code: string) {
    super(`The authorization server rejected the refresh (${code})`)
  }
}

export class McpRefreshUnavailable extends Error {
  constructor(readonly detail: string) {
    super(`The authorization server is unavailable (${detail})`)
  }
}

const GrantSchema = z.object({
  authorizationServerUrl: z.string(),
  authorizationServerMetadata: z
    .union([OAuthMetadataSchema, OpenIdProviderDiscoveryMetadataSchema])
    .optional(),
  resource: z.string().optional(),
  client: z.union([OAuthClientInformationFullSchema, OAuthClientInformationSchema])
})

export interface McpGrant {
  readonly authorizationServerUrl: string
  readonly authorizationServerMetadata?: z.infer<typeof GrantSchema>["authorizationServerMetadata"]
  readonly resource?: URL
  readonly client: OAuthClientInformationMixed
}

export const mcpTokenBundle = (
  serverUrl: string,
  grant: McpGrant,
  tokens: OAuthTokens,
  now: number
): McpTokenBundle => ({
  harnessId: "mcp",
  subject: grant.resource?.toString() ?? serverUrl,
  accessToken: tokens.access_token,
  ...(tokens.refresh_token === undefined ? {} : { refreshToken: tokens.refresh_token }),
  expiresAt:
    tokens.expires_in === undefined ? Number.MAX_SAFE_INTEGER : now + tokens.expires_in * 1000,
  ...(tokens.scope === undefined ? {} : { scopes: tokens.scope.split(" ") }),
  ownership: "managed",
  credential: {
    authorizationServerUrl: grant.authorizationServerUrl,
    ...(grant.authorizationServerMetadata === undefined
      ? {}
      : { authorizationServerMetadata: grant.authorizationServerMetadata }),
    ...(grant.resource === undefined ? {} : { resource: grant.resource.toString() }),
    client: grant.client
  }
})

const UNSENT_CONNECTION_FAILURES = new Set([
  "ECONNREFUSED",
  "ENOTFOUND",
  "EAI_AGAIN",
  "ENETUNREACH",
  "EHOSTUNREACH",
  "UND_ERR_CONNECT_TIMEOUT"
])

const connectionFailureCode = (cause: unknown): string | undefined => {
  if (!(cause instanceof TypeError) || !isRecord(cause.cause)) return undefined
  const code = cause.cause.code
  return typeof code === "string" && UNSENT_CONNECTION_FAILURES.has(code) ? code : undefined
}

const classified = (cause: unknown): unknown => {
  if (
    cause instanceof ServerError ||
    cause instanceof TemporarilyUnavailableError ||
    cause instanceof TooManyRequestsError
  ) {
    return new McpRefreshUnavailable(cause.errorCode)
  }
  if (cause instanceof OAuthError) return new McpRefreshRejected(cause.errorCode)
  const unsent = connectionFailureCode(cause)
  return unsent === undefined ? cause : new McpRefreshUnavailable(unsent)
}

export const refreshMcpOAuth = async (
  bundle: McpTokenBundle,
  options: { readonly fetch?: typeof fetch; readonly now?: () => number } = {}
): Promise<McpTokenBundle> => {
  const parsed = GrantSchema.safeParse(bundle.credential)
  if (!parsed.success || bundle.refreshToken === undefined) {
    throw new McpRefreshRejected("missing_grant")
  }
  const grant = parsed.data
  const request = options.fetch ?? fetch
  let tokens: OAuthTokens
  try {
    tokens = await refreshAuthorization(grant.authorizationServerUrl, {
      ...(grant.authorizationServerMetadata === undefined
        ? {}
        : { metadata: grant.authorizationServerMetadata }),
      clientInformation: grant.client,
      refreshToken: bundle.refreshToken,
      ...(grant.resource === undefined ? {} : { resource: new URL(grant.resource) }),
      fetchFn: (url, init) =>
        request(url, { ...init, redirect: "error", signal: AbortSignal.timeout(15_000) })
    })
  } catch (cause) {
    throw classified(cause)
  }
  const now = (options.now ?? Date.now)()
  return {
    ...bundle,
    accessToken: tokens.access_token,
    /* v8 ignore next */
    refreshToken: tokens.refresh_token ?? bundle.refreshToken,
    expiresAt:
      tokens.expires_in === undefined ? Number.MAX_SAFE_INTEGER : now + tokens.expires_in * 1000,
    ...(tokens.scope === undefined ? {} : { scopes: tokens.scope.split(" ") })
  }
}

export type McpCredentialFailure = "rejected" | "revoked" | "reauthorize" | "busy" | "unavailable"

export const mcpCredentialFailure = (cause: unknown): McpCredentialFailure => {
  if (!isRecord(cause)) return "unavailable"
  if (cause.reason === "revoked") return "revoked"
  if (cause.reason === "busy") return "busy"
  if (cause.reason === "reauthenticate") {
    return typeof cause.status === "number" ? "rejected" : "reauthorize"
  }
  return "unavailable"
}

import { randomBytes } from "node:crypto"

import type { PluginOAuthSpec } from "@codevisor/api"
import type { SharedTokenBundle } from "@codevisor/harness-manager"
import { exchangeAuthorization, startAuthorization } from "@modelcontextprotocol/sdk/client/auth.js"
import type { OAuthTokens } from "@modelcontextprotocol/sdk/shared/auth.js"

import { field } from "../../unknown-values.js"

export interface OAuthClient {
  readonly clientId: string
  readonly clientSecret?: string
}

export interface PendingOAuthFlow {
  readonly flowId: string
  readonly nonce: string
  readonly serverId: string
  readonly plugin: string
  readonly accountId?: string
  readonly label?: string
  readonly values: Readonly<Record<string, string | number | boolean>>
  readonly secrets: Readonly<Record<string, string>>
  readonly client: OAuthClient
  readonly redirectUri: string
  readonly codeVerifier: string
  readonly expiresAt: number
}

export interface StartedOAuth {
  readonly authorizationUrl: string
  readonly codeVerifier: string
}

export const oauthFlowLifetimeMs = 15 * 60_000

export const newFlowId = (): string => randomBytes(24).toString("base64url")

export const newNonce = (): string => randomBytes(12).toString("base64url")

export const flowState = (flowId: string, deviceId: string, nonce: string): string =>
  `${flowId}.${deviceId}.${nonce}`

export const parseFlowState = (
  state: string
): { readonly flowId: string; readonly nonce: string } | undefined => {
  const parts = state.split(".")
  if (parts.length !== 3) return undefined
  const [flowId, , nonce] = parts
  if (flowId === undefined || nonce === undefined || flowId === "" || nonce === "") return undefined
  return { flowId, nonce }
}

export const beginPluginOAuth = async (
  spec: PluginOAuthSpec,
  client: OAuthClient,
  redirectUri: string,
  state: string
): Promise<StartedOAuth> => {
  const started = await startAuthorization(issuerOf(spec), {
    metadata: authorizationMetadata(spec),
    clientInformation: clientInformation(client),
    redirectUrl: redirectUri,
    scope: spec.scopes.join(" "),
    state
  })
  for (const [name, value] of Object.entries(spec.authorizeParams ?? {})) {
    started.authorizationUrl.searchParams.set(name, value)
  }
  return {
    authorizationUrl: started.authorizationUrl.toString(),
    codeVerifier: started.codeVerifier
  }
}

export const exchangePluginCode = (
  spec: PluginOAuthSpec,
  flow: PendingOAuthFlow,
  code: string,
  fetchFn: typeof fetch = fetch
): Promise<OAuthTokens> =>
  exchangeAuthorization(issuerOf(spec), {
    metadata: authorizationMetadata(spec),
    clientInformation: clientInformation(flow.client),
    authorizationCode: code,
    codeVerifier: flow.codeVerifier,
    redirectUri: flow.redirectUri,
    fetchFn: (url, init) => fetchFn(url, { ...init, redirect: "error" })
  })

export const oauthBundle = (
  spec: PluginOAuthSpec,
  flow: PendingOAuthFlow,
  tokens: OAuthTokens,
  identity: string,
  now: number
): SharedTokenBundle => ({
  harnessId: "plugin",
  subject: identity,
  accessToken: tokens.access_token,
  ...(tokens.refresh_token === undefined ? {} : { refreshToken: tokens.refresh_token }),
  expiresAt:
    tokens.expires_in === undefined ? Number.MAX_SAFE_INTEGER : now + tokens.expires_in * 1000,
  ...(tokens.scope === undefined ? {} : { scopes: tokens.scope.split(" ") }),
  ownership: "managed",
  credential: {
    authorizationServerUrl: issuerOf(spec),
    authorizationServerMetadata: authorizationMetadata(spec),
    client: clientInformation(flow.client),
    secrets: flow.secrets
  }
})

export const fetchIdentity = async (
  spec: PluginOAuthSpec,
  accessToken: string,
  fetchFn: typeof fetch = fetch
): Promise<string | undefined> => {
  if (spec.userinfoUrl === undefined) return undefined
  const response = await fetchFn(spec.userinfoUrl, {
    headers: { authorization: `Bearer ${accessToken}` },
    redirect: "error",
    signal: AbortSignal.timeout(15_000)
  })
  if (!response.ok) return undefined
  const body: unknown = await response.json()
  const value = identityValue(body, spec.identityField ?? "email")
  return typeof value === "string" ? value : undefined
}

const identityValue = (body: unknown, key: string): unknown => field(body, key)

const issuerOf = (spec: PluginOAuthSpec): string => new URL(spec.authorizeUrl).origin

const authorizationMetadata = (spec: PluginOAuthSpec) => ({
  issuer: issuerOf(spec),
  authorization_endpoint: spec.authorizeUrl,
  token_endpoint: spec.tokenUrl,
  response_types_supported: ["code"],
  grant_types_supported: ["authorization_code", "refresh_token"],
  code_challenge_methods_supported: ["S256"],
  token_endpoint_auth_methods_supported: ["client_secret_post", "none"]
})

const clientInformation = (client: OAuthClient) => ({
  client_id: client.clientId,
  ...(client.clientSecret === undefined ? {} : { client_secret: client.clientSecret })
})

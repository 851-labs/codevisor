import { randomBytes } from "node:crypto"

import type { PluginOAuthSpec } from "@codevisor/api"
import type { SharedTokenBundle } from "@codevisor/harness-manager"
import { exchangeAuthorization, startAuthorization } from "@modelcontextprotocol/client"
import type { OAuthTokens } from "@modelcontextprotocol/client"

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

export const flowState = (flowId: string, returnTo: string, nonce: string): string =>
  `${flowId}.${returnTo}.${nonce}`

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
    scope: spec.scopes.join(spec.scopeDelimiter ?? " "),
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

export interface AccountIdentity {
  readonly identity?: string
  readonly routeKey?: string
}

export const fetchAccountIdentity = async (
  spec: PluginOAuthSpec,
  accessToken: string,
  fetchFn: typeof fetch = fetch
): Promise<AccountIdentity> => {
  if (spec.userinfoUrl === undefined) return {}
  const response = await fetchFn(spec.userinfoUrl, userinfoRequest(spec, accessToken))
  if (!response.ok) return {}
  const body: unknown = await response.json()
  return {
    ...stringAt(body, "identity", spec.identityField ?? "email"),
    ...stringAt(body, "routeKey", spec.routeKeyField)
  }
}

const userinfoRequest = (spec: PluginOAuthSpec, accessToken: string): RequestInit => {
  const request = {
    headers: { authorization: `Bearer ${accessToken}` },
    redirect: "error" as const,
    signal: AbortSignal.timeout(15_000)
  }
  if (spec.userinfoQuery === undefined) return request

  return {
    ...request,
    method: "POST",
    headers: { ...request.headers, "content-type": "application/json" },
    body: JSON.stringify({ query: spec.userinfoQuery })
  }
}

const stringAt = (
  body: unknown,
  name: keyof AccountIdentity,
  path: string | undefined
): AccountIdentity => {
  if (path === undefined) return {}
  const value = path.split(".").reduce<unknown>((parent, key) => field(parent, key), body)
  return typeof value === "string" ? { [name]: value } : {}
}

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

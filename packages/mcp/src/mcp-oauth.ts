import type { McpServerRecord } from "@codevisor/db"
import {
  discoverOAuthServerInfo,
  selectResourceURL
} from "@modelcontextprotocol/sdk/client/auth.js"
import type {
  OAuthClientInformationMixed,
  OAuthTokens
} from "@modelcontextprotocol/sdk/shared/auth.js"

import type { StreamableHttpAuthorization } from "./mcp-http-transport.js"
import type { McpOAuthClock } from "./mcp-oauth-clock.js"
import {
  type McpCredentialReference,
  mcpCredentialFailure,
  type McpGrant,
  type McpOAuthVault,
  mcpTokenBundle
} from "./mcp-oauth-grant.js"
import { configuredClient, makeOAuthProvider, registeredClient } from "./mcp-oauth-provider.js"
import type { StoredOAuth, StoredSecrets } from "./mcp-secret-store.js"
import { errorMessage, reportBackgroundFailure, requireHttpUrl } from "./mcp-support.js"

const FIRST_RETRY_DELAY_MS = 30_000
const MAX_RETRY_DELAY_MS = 15 * 60_000

const ownsLegacyTokens = (oauth: StoredOAuth | undefined, selfServerId: string): boolean =>
  oauth?.refreshOwner === undefined || oauth.refreshOwner === selfServerId

const legacyExpiry = (oauth: StoredOAuth): number => {
  const expiresIn = oauth.tokens?.expires_in
  if (expiresIn === undefined) return Number.MAX_SAFE_INTEGER
  return (oauth.tokensSavedAt ?? 0) + expiresIn * 1000
}

class McpAuthorizationError extends Error {}

export interface McpOAuthRuntimeDeps {
  readonly callbackUrl: () => string
  readonly cancelOAuthRetry: (id: string) => void
  readonly clock: McpOAuthClock
  readonly closeConnection: (id: string) => Promise<void>
  readonly connectUpstream: (
    id: string,
    options?: { readonly allowDisabled?: boolean; readonly preserveState?: boolean }
  ) => Promise<unknown>
  readonly hasConnection: (id: string) => boolean
  readonly oauthRetries: Map<string, () => void>
  readonly record: (id: string) => Promise<McpServerRecord>
  readonly refreshGatewayInventories: () => Promise<void>
  readonly replaceSecrets: (
    id: string,
    mutate: (current: StoredSecrets) => StoredSecrets
  ) => Promise<McpServerRecord>
  readonly saveRecord: (
    server: McpServerRecord,
    patch?: Partial<McpServerRecord>
  ) => Promise<McpServerRecord>
  readonly secrets: (server: McpServerRecord) => StoredSecrets
  readonly selfServerId: string
  readonly vault: McpOAuthVault | undefined
  readonly onCredentialChanged: (serverId: string) => void
}

export const makeMcpOAuthRuntime = (deps: McpOAuthRuntimeDeps) => {
  const {
    callbackUrl,
    cancelOAuthRetry,
    clock,
    closeConnection,
    connectUpstream,
    oauthRetries,
    record,
    refreshGatewayInventories,
    replaceSecrets,
    saveRecord,
    secrets,
    selfServerId
  } = deps
  const backoffs = new Map<string, { readonly until: number; readonly attempt: number }>()
  const lastTokens = new Map<string, { readonly accessToken: string; readonly expiresAt: number }>()
  const migrations = new Map<string, Promise<McpCredentialReference | undefined>>()

  const requireVault = (): McpOAuthVault => {
    if (deps.vault === undefined) throw new Error("MCP sign-in storage is unavailable")
    return deps.vault
  }

  const oauthProvider = makeOAuthProvider({
    callbackUrl,
    record,
    replaceSecrets,
    secrets,
    saveTokens: (serverId, redirectUrl, tokens) => establishGrant(serverId, redirectUrl, tokens)
  })

  const grantFor = async (
    server: McpServerRecord,
    oauth: StoredOAuth,
    client: OAuthClientInformationMixed
  ): Promise<McpGrant> => {
    const serverUrl = new URL(requireHttpUrl(server.url))
    let discovery = oauth.discoveryState
    if (discovery === undefined) {
      const discovered = await discoverOAuthServerInfo(serverUrl)
      discovery = {
        authorizationServerUrl: discovered.authorizationServerUrl,
        ...(discovered.resourceMetadata === undefined
          ? {}
          : { resourceMetadata: discovered.resourceMetadata }),
        ...(discovered.authorizationServerMetadata === undefined
          ? {}
          : { authorizationServerMetadata: discovered.authorizationServerMetadata })
      }
    }
    const resource = await selectResourceURL(
      serverUrl,
      oauthProvider(server.id),
      discovery.resourceMetadata
    )
    return {
      authorizationServerUrl: discovery.authorizationServerUrl,
      ...(discovery.authorizationServerMetadata === undefined
        ? {}
        : { authorizationServerMetadata: discovery.authorizationServerMetadata }),
      ...(resource === undefined ? {} : { resource }),
      client
    }
  }

  const adoptCredential = async (id: string, credential: McpCredentialReference) => {
    backoffs.delete(id)
    lastTokens.delete(id)
    cancelOAuthRetry(id)
    return replaceSecrets(id, (value) => ({
      ...value,
      oauth: {
        ...value.oauth,
        credential,
        tokens: undefined,
        tokensSavedAt: undefined,
        refreshOwner: undefined,
        clientInformation: undefined
      }
    }))
  }

  const establishGrant = async (
    id: string,
    redirectUrl: string,
    tokens: OAuthTokens
  ): Promise<void> => {
    const vault = requireVault()
    const server = await record(id)
    const oauth = secrets(server).oauth ?? {}
    const client = registeredClient(oauth, redirectUrl)
    if (client === undefined) throw new Error("OAuth client registration is missing")
    const grant = await grantFor(server, oauth, client)
    const credential = await vault.create(
      mcpTokenBundle(requireHttpUrl(server.url), grant, tokens, clock.now())
    )
    await adoptCredential(id, credential)
    deps.onCredentialChanged(id)
  }

  const performMigration = async (id: string): Promise<McpCredentialReference | undefined> => {
    const server = await record(id)
    const oauth = secrets(server).oauth
    const tokens = oauth?.tokens
    if (
      deps.vault === undefined ||
      oauth === undefined ||
      tokens === undefined ||
      (oauth.credential ?? undefined) !== undefined ||
      !ownsLegacyTokens(oauth, selfServerId)
    ) {
      return undefined
    }
    const client = oauth.clientInformation ?? configuredClient(oauth)
    if (client === undefined) return undefined
    try {
      const grant = await grantFor(server, oauth, client)
      const credential = await deps.vault.create({
        ...mcpTokenBundle(requireHttpUrl(server.url), grant, tokens, clock.now()),
        expiresAt: legacyExpiry(oauth)
      })
      await replaceSecrets(id, (value) => ({
        ...value,
        oauth: {
          ...value.oauth,
          ...(value.oauth?.redirectUrl === undefined || configuredClient(value.oauth) !== undefined
            ? {}
            : {
                registrations: {
                  ...value.oauth.registrations,
                  [value.oauth.redirectUrl]: client
                }
              })
        }
      }))
      await adoptCredential(id, credential)
      deps.onCredentialChanged(id)
      return credential
    } catch (cause) {
      reportBackgroundFailure(`Moving the ${server.name} sign-in to shared storage failed`, cause)
      return undefined
    }
  }

  const migrateLegacyGrant = (id: string): Promise<McpCredentialReference | undefined> => {
    const pending = migrations.get(id)
    if (pending !== undefined) return pending
    const migrating = performMigration(id).finally(() => migrations.delete(id))
    migrations.set(id, migrating)
    return migrating
  }

  const markState = async (
    id: string,
    connectionState: "expired" | "needsAuthorization",
    detail: string
  ): Promise<void> => {
    const current = await record(id)
    if (current.connectionState === connectionState && current.detail === detail) return
    await saveRecord(current, {
      connectionState,
      detail,
      ...(connectionState === "needsAuthorization" ? { toolCount: 0 } : {})
    })
    await refreshGatewayInventories()
  }

  const scheduleRetry = (id: string, attempt: number): void => {
    cancelOAuthRetry(id)
    const delay = Math.min(MAX_RETRY_DELAY_MS, FIRST_RETRY_DELAY_MS * 2 ** (attempt - 1))
    backoffs.set(id, { until: clock.now() + delay, attempt })
    oauthRetries.set(
      id,
      clock.setTimeout(() => {
        oauthRetries.delete(id)
        backoffs.set(id, { until: clock.now(), attempt })
        void accessToken(id).catch(() => undefined)
      }, delay)
    )
  }

  const recovered = async (id: string): Promise<void> => {
    if (backoffs.has(id)) {
      backoffs.delete(id)
      cancelOAuthRetry(id)
    }
    const current = await record(id)
    if (current.connectionState !== "expired") return
    const connected = deps.hasConnection(id)
    await saveRecord(current, {
      connectionState: connected ? "connected" : "disconnected",
      detail: undefined
    })
    if (current.enabled && !connected) void connectUpstream(id).catch(() => undefined)
    await refreshGatewayInventories()
  }

  const signedOut = async (
    server: McpServerRecord,
    credential: McpCredentialReference,
    detail: string
  ): Promise<McpAuthorizationError> => {
    lastTokens.delete(server.id)
    backoffs.delete(server.id)
    cancelOAuthRetry(server.id)
    let cleared = false
    await replaceSecrets(server.id, (value) => {
      if (value.oauth?.credential?.id !== credential.id) return value
      cleared = true
      return { ...value, oauth: { ...value.oauth, credential: null } }
    })
    await markState(server.id, "needsAuthorization", detail)
    if (cleared) deps.onCredentialChanged(server.id)
    return new McpAuthorizationError(detail)
  }

  const accessToken = async (id: string, rejectedAccessToken?: string): Promise<string> => {
    const server = await record(id)
    const oauth = secrets(server).oauth
    const credential = oauth?.credential ?? (await migrateLegacyGrant(id))
    const reauthorize = `${server.name} needs authorization. Authorize it in Codevisor's MCP settings.`
    if (credential === undefined || credential === null) {
      const legacy = oauth?.tokens
      if (
        legacy !== undefined &&
        legacy.access_token !== rejectedAccessToken &&
        clock.now() < legacyExpiry(oauth ?? {})
      ) {
        return legacy.access_token
      }
      await markState(id, "needsAuthorization", reauthorize)
      throw new McpAuthorizationError(reauthorize)
    }
    const backoff = backoffs.get(id)
    if (backoff !== undefined && clock.now() < backoff.until) {
      const last = lastTokens.get(id)
      if (
        last !== undefined &&
        last.accessToken !== rejectedAccessToken &&
        clock.now() < last.expiresAt
      ) {
        return last.accessToken
      }
      throw new McpAuthorizationError(
        `Couldn't renew the ${server.name} sign-in. Codevisor retries automatically.`
      )
    }
    const vault = requireVault()
    try {
      const token = await vault.token(credential, rejectedAccessToken)
      lastTokens.set(id, token)
      await recovered(id)
      return token.accessToken
    } catch (cause) {
      const failure = mcpCredentialFailure(cause)
      if (failure === "busy") {
        throw new McpAuthorizationError(
          `The ${server.name} sign-in is being renewed on another of your machines. Try again in a moment.`
        )
      }
      if (failure === "unavailable") {
        scheduleRetry(id, (backoff?.attempt ?? 0) + 1)
        const detail = `Couldn't renew the ${server.name} sign-in (${errorMessage(cause)}). Codevisor retries automatically.`
        await markState(id, "expired", detail)
        throw new McpAuthorizationError(detail)
      }
      if (failure === "reauthorize") {
        const detail = `The ${server.name} sign-in can't be used on this machine. Authorize it again.`
        await markState(id, "needsAuthorization", detail)
        throw new McpAuthorizationError(detail)
      }
      if (failure === "rejected") {
        await vault
          .revoke(credential)
          .catch((revokeFailure: unknown) =>
            reportBackgroundFailure(`Revoking the ${server.name} sign-in failed`, revokeFailure)
          )
      }
      throw await signedOut(
        server,
        credential,
        `The ${server.name} sign-in expired or was revoked. Authorize it again.`
      )
    }
  }

  const upstreamAuthorization = (id: string): StreamableHttpAuthorization => ({
    accessToken: () => accessToken(id),
    recoverUnauthorized: async (rejectedAccessToken) => {
      try {
        const renewed = await accessToken(id, rejectedAccessToken)
        return renewed === rejectedAccessToken
          ? { retry: false, reason: "The MCP server rejected its renewed sign-in" }
          : { retry: true }
      } catch (cause) {
        return { retry: false, reason: errorMessage(cause) }
      }
    }
  })

  const adoptSyncedCredential = async (
    id: string,
    credential: McpCredentialReference | null
  ): Promise<void> => {
    const current = await record(id)
    const held = secrets(current).oauth?.credential
    if (held === credential || (held != null && held.id === credential?.id)) return
    if (credential === null) {
      await replaceSecrets(id, (value) => ({
        ...value,
        oauth: { ...value.oauth, credential: null }
      }))
      lastTokens.delete(id)
      backoffs.delete(id)
      cancelOAuthRetry(id)
      await closeConnection(id)
      await markState(
        id,
        "needsAuthorization",
        `${current.name} was signed out on another of your machines. Authorize it again.`
      )
      return
    }
    const adopted = await adoptCredential(id, credential)
    if (adopted.enabled && !deps.hasConnection(id)) {
      void connectUpstream(id).catch(() => undefined)
    }
  }

  const revokeCredential = async (id: string): Promise<void> => {
    const credential = secrets(await record(id)).oauth?.credential
    lastTokens.delete(id)
    backoffs.delete(id)
    cancelOAuthRetry(id)
    if (credential == null || deps.vault === undefined) return
    await deps.vault
      .revoke(credential)
      .catch((cause: unknown) =>
        reportBackgroundFailure(`Revoking the MCP ${id} sign-in failed`, cause)
      )
  }

  const hasUsableCredential = async (id: string): Promise<boolean> => {
    const credential = secrets(await record(id)).oauth?.credential
    if (credential == null || deps.vault === undefined) return false
    try {
      await deps.vault.token(credential)
      return true
    } catch {
      return false
    }
  }

  const validateOAuthConnection = async (id: string): Promise<void> => {
    try {
      await connectUpstream(id, { allowDisabled: true, preserveState: true })
      await saveRecord(await record(id), {
        connectionState: "connected",
        detail: undefined
      })
    } catch (cause) {
      await closeConnection(id)
      const current = await record(id)
      await saveRecord(current, {
        connectionState: "needsAuthorization",
        toolCount: 0,
        detail: undefined
      })
      console.error(`OAuth validation failed for ${current.name}: ${errorMessage(cause)}`)
    }
    await refreshGatewayInventories()
  }

  return {
    adoptSyncedCredential,
    hasUsableCredential,
    migrateLegacyGrant,
    oauthProvider,
    revokeCredential,
    upstreamAuthorization,
    validateOAuthConnection
  }
}

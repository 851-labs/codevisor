import { auth, type OAuthClientProvider } from "@modelcontextprotocol/sdk/client/auth.js"
import type { OAuthClientMetadata, OAuthTokens } from "@modelcontextprotocol/sdk/shared/auth.js"
import type { McpServerRecord } from "@codevisor/db"
import type { StoredSecrets } from "./mcp-secret-store.js"
import { errorMessage, reportBackgroundFailure, requireHttpUrl } from "./mcp-support.js"

const MAX_TIMER_DELAY_MS = 2_147_000_000

export const boundedMcpTimerDelay = (delay: number): number =>
  Math.min(Math.max(1, delay), MAX_TIMER_DELAY_MS)

export interface McpOAuthRuntimeDeps {
  readonly callbackUrl: () => string
  readonly closeConnection: (id: string) => Promise<void>
  readonly connectUpstream: (
    id: string,
    options?: { readonly allowDisabled?: boolean; readonly preserveState?: boolean }
  ) => Promise<unknown>
  readonly record: (id: string) => Promise<McpServerRecord>
  readonly refreshGatewayInventories: () => Promise<void>
  readonly refreshLocks: Map<string, Promise<void>>
  readonly refreshRetryAttempts: Map<string, number>
  readonly refreshTimers: Map<string, ReturnType<typeof setTimeout>>
  readonly replaceSecrets: (
    id: string,
    mutate: (current: StoredSecrets) => StoredSecrets
  ) => Promise<McpServerRecord>
  readonly saveRecord: (
    server: McpServerRecord,
    patch?: Partial<McpServerRecord>
  ) => Promise<McpServerRecord>
  readonly secrets: (server: McpServerRecord) => StoredSecrets
  /// This machine's server id — refresh-ownership identity.
  readonly selfServerId: string
  /// Fires after tokens are saved (authorize or refresh) so the config
  /// plane can republish the rotated material immediately.
  readonly onRotated: (serverId: string) => void
}

export const makeMcpOAuthRuntime = (deps: McpOAuthRuntimeDeps) => {
  const {
    callbackUrl,
    closeConnection,
    connectUpstream,
    record,
    refreshGatewayInventories,
    refreshLocks,
    refreshRetryAttempts,
    refreshTimers,
    replaceSecrets,
    saveRecord,
    secrets
  } = deps

  /* v8 ignore start -- the OAuth SDK callback contract, browser redirect, token refresh, and
   * retry timers are exercised against live OAuth MCP providers in the macOS integration flow. */
  const oauthProvider = (
    serverId: string,
    savedRedirectUrl?: string
  ): OAuthClientProvider & { authorizationUrl?: URL } => {
    const redirectUrl = savedRedirectUrl ?? callbackUrl()
    const provider: OAuthClientProvider & { authorizationUrl?: URL } = {
      redirectUrl,
      get clientMetadata(): OAuthClientMetadata {
        return {
          client_name: "Codevisor",
          redirect_uris: [redirectUrl],
          grant_types: ["authorization_code", "refresh_token"],
          response_types: ["code"],
          token_endpoint_auth_method: "none",
          scope: undefined
        }
      },
      state: async () => secrets(await record(serverId)).oauth?.state ?? "",
      clientInformation: async () => {
        const oauth = secrets(await record(serverId)).oauth
        if (oauth?.clientInformation !== undefined) return oauth.clientInformation
        if (oauth?.configuredClientId === undefined) return undefined
        return {
          client_id: oauth.configuredClientId,
          ...(oauth.configuredClientSecret === undefined
            ? {}
            : { client_secret: oauth.configuredClientSecret })
        }
      },
      saveClientInformation: async (clientInformation) => {
        await replaceSecrets(serverId, (value) => ({
          ...value,
          oauth: { ...value.oauth, clientInformation }
        }))
      },
      tokens: async () => secrets(await record(serverId)).oauth?.tokens,
      saveTokens: async (tokens) => {
        // Saving tokens IS taking (or keeping) refresh ownership: a fresh
        // authorize anywhere makes that machine the one rotator.
        const saved = await replaceSecrets(serverId, (value) => ({
          ...value,
          oauth: {
            ...value.oauth,
            tokens,
            tokensSavedAt: Date.now(),
            refreshOwner: deps.selfServerId
          }
        }))
        scheduleRefresh(saved, tokens)
        deps.onRotated(serverId)
      },
      redirectToAuthorization: (authorizationUrl) => {
        provider.authorizationUrl = authorizationUrl
      },
      saveCodeVerifier: async (codeVerifier) => {
        await replaceSecrets(serverId, (value) => ({
          ...value,
          oauth: { ...value.oauth, codeVerifier }
        }))
      },
      codeVerifier: async () => {
        const value = secrets(await record(serverId)).oauth?.codeVerifier
        if (value === undefined) throw new Error("OAuth code verifier is missing")
        return value
      },
      saveDiscoveryState: async (discoveryState) => {
        await replaceSecrets(serverId, (value) => ({
          ...value,
          oauth: { ...value.oauth, discoveryState }
        }))
      },
      discoveryState: async () => secrets(await record(serverId)).oauth?.discoveryState,
      invalidateCredentials: async (scope) => {
        await replaceSecrets(serverId, (value) => {
          if (scope === "all") return { ...value, oauth: undefined }
          if (scope === "tokens") return { ...value, oauth: { ...value.oauth, tokens: undefined } }
          if (scope === "verifier") {
            return { ...value, oauth: { ...value.oauth, codeVerifier: undefined } }
          }
          if (scope === "discovery") {
            return { ...value, oauth: { ...value.oauth, discoveryState: undefined } }
          }
          return { ...value, oauth: { ...value.oauth, clientInformation: undefined } }
        })
      }
    }
    return provider
  }

  const scheduleRefresh = (server: McpServerRecord, tokens: OAuthTokens): void => {
    const existing = refreshTimers.get(server.id)
    if (existing !== undefined) clearTimeout(existing)
    // Mirrors never rotate: another machine owns this token family, and a
    // concurrent refresh here would invalidate it fleet-wide.
    const owner = secrets(server).oauth?.refreshOwner
    if (owner !== undefined && owner !== deps.selfServerId) return
    if (tokens.refresh_token === undefined || tokens.expires_in === undefined) return
    const savedAt = secrets(server).oauth?.tokensSavedAt ?? Date.now()
    const elapsed = Math.max(0, Date.now() - savedAt)
    const jitter = Math.floor(Math.random() * 30_000)
    const delay = Math.max(1_000, tokens.expires_in * 1000 - elapsed - 120_000 - jitter)
    const timerDelay = boundedMcpTimerDelay(delay)
    const timer = setTimeout(() => {
      if (delay <= MAX_TIMER_DELAY_MS) {
        void refreshOAuth(server.id).catch((cause: unknown) =>
          reportBackgroundFailure(`OAuth refresh failed for MCP ${server.id}`, cause)
        )
        return
      }
      void record(server.id)
        .then((current) => {
          const currentTokens = secrets(current).oauth?.tokens
          if (currentTokens !== undefined) scheduleRefresh(current, currentTokens)
        })
        .catch(() => undefined)
    }, timerDelay)
    timer.unref?.()
    refreshTimers.set(server.id, timer)
  }

  const scheduleRefreshRetry = (id: string): void => {
    const attempt = (refreshRetryAttempts.get(id) ?? 0) + 1
    refreshRetryAttempts.set(id, attempt)
    const delay = Math.min(15 * 60_000, 30_000 * 2 ** Math.min(attempt - 1, 5))
    const timer = setTimeout(
      () =>
        void refreshOAuth(id).catch((cause: unknown) =>
          reportBackgroundFailure(`OAuth refresh retry failed for MCP ${id}`, cause)
        ),
      delay + Math.random() * 10_000
    )
    timer.unref?.()
    refreshTimers.set(id, timer)
  }

  const performRefreshOAuth = async (id: string): Promise<void> => {
    const current = await record(id)
    if (current.authType !== "oauth") return
    try {
      const result = await auth(oauthProvider(id, secrets(current).oauth?.redirectUrl), {
        serverUrl: requireHttpUrl(current.url),
        ...(current.oauthScope === undefined ? {} : { scope: current.oauthScope })
      })
      if (result !== "AUTHORIZED") throw new Error("OAuth reauthorization is required")
      refreshRetryAttempts.delete(id)
      const updated = await record(id)
      await saveRecord(updated, { connectionState: "connected", detail: undefined })
      await closeConnection(id)
      await refreshGatewayInventories()
    } catch (cause) {
      // A failed refresh is THIS machine's observation, never a fleet
      // decision: the enabled wish stays put (it is config-synced) and the
      // expiry travels through connection state and readiness instead.
      const updated = await record(id)
      await saveRecord(updated, {
        connectionState: "expired",
        detail: `Authorization refresh failed: ${errorMessage(cause)}`
      })
      await refreshGatewayInventories()
      scheduleRefreshRetry(id)
    }
  }

  const refreshOAuth = async (id: string): Promise<void> => {
    const existing = refreshLocks.get(id)
    if (existing !== undefined) return existing
    const refreshing = performRefreshOAuth(id).finally(() => refreshLocks.delete(id))
    refreshLocks.set(id, refreshing)
    return refreshing
  }
  /* v8 ignore stop */

  /* v8 ignore start -- completion validation requires a live OAuth provider and upstream MCP. */
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
  /* v8 ignore stop */

  return { oauthProvider, scheduleRefresh, validateOAuthConnection }
}

import type { McpServerRecord } from "@codevisor/db"
import type { OAuthTokens } from "@modelcontextprotocol/sdk/shared/auth.js"
import type { McpManagerCore } from "./mcp-manager-core.js"
import type { McpManager } from "./mcp-manager-types.js"
import type { StoredOAuth } from "./mcp-secret-store.js"
import { run } from "./mcp-support.js"

export type McpReplicationOperations = Pick<
  McpManager,
  | "adoptOAuthOwnership"
  | "importOAuthMaterial"
  | "oauthSyncState"
  | "staticSecrets"
  | "subscribeCredentialsRotated"
>

export interface McpReplicationDeps {
  /// Re-arms the refresh timer for tokens this machine now owns.
  readonly scheduleRefresh: (server: McpServerRecord, tokens: OAuthTokens) => void
  /// Opens the upstream with freshly imported material so a mirror reports
  /// the same connected state as the owner instead of "needs authorization".
  readonly connect: (id: string) => Promise<unknown>
}

/// The config-plane replication surface: static secrets travel as-is, OAuth
/// material travels under refresh ownership so exactly one machine rotates.
export const makeMcpReplicationOperations = (
  core: McpManagerCore,
  deps: McpReplicationDeps
): McpReplicationOperations => {
  const {
    closeConnection,
    config,
    record,
    refreshTimers,
    replaceSecrets,
    rotationListeners,
    secrets,
    selfServerId,
    state
  } = core

  const staticSecrets: McpManager["staticSecrets"] = async (id) => {
    const stored = secrets(await record(id))
    return {
      ...(stored.bearerToken === undefined || stored.bearerToken === ""
        ? {}
        : { bearerToken: stored.bearerToken }),
      ...(stored.headers === undefined ? {} : { headers: stored.headers }),
      ...(stored.env === undefined ? {} : { env: stored.env })
    }
  }

  const oauthSyncState: McpManager["oauthSyncState"] = async (id) => {
    const server = await record(id)
    if (server.authType !== "oauth") return undefined
    const oauth = secrets(server).oauth
    if (oauth?.tokens === undefined) return undefined
    const material: StoredOAuth = {
      ...(oauth.clientInformation === undefined
        ? {}
        : { clientInformation: oauth.clientInformation }),
      tokens: oauth.tokens,
      ...(oauth.tokensSavedAt === undefined ? {} : { tokensSavedAt: oauth.tokensSavedAt }),
      ...(oauth.discoveryState === undefined ? {} : { discoveryState: oauth.discoveryState }),
      ...(oauth.configuredClientId === undefined
        ? {}
        : { configuredClientId: oauth.configuredClientId }),
      ...(oauth.configuredClientSecret === undefined
        ? {}
        : { configuredClientSecret: oauth.configuredClientSecret })
    }
    return {
      owner: oauth.refreshOwner ?? selfServerId,
      rotatedAtMs: oauth.tokensSavedAt ?? 0,
      material: JSON.stringify(material)
    }
  }

  const importOAuthMaterial: McpManager["importOAuthMaterial"] = async (id, incoming) => {
    const current = secrets(await record(id)).oauth
    let parsed: StoredOAuth
    try {
      parsed = JSON.parse(incoming.material) as StoredOAuth
    } catch {
      return
    }
    if (typeof parsed !== "object" || parsed === null) return
    // Identical re-imports must not thrash the live connection.
    if (
      current?.refreshOwner === incoming.owner &&
      (current?.tokensSavedAt ?? 0) === (parsed.tokensSavedAt ?? 0)
    ) {
      return
    }
    const timer = refreshTimers.get(id)
    if (timer !== undefined) clearTimeout(timer)
    refreshTimers.delete(id)
    const updated = await replaceSecrets(id, (value) => ({
      ...value,
      oauth: { ...parsed, refreshOwner: incoming.owner }
    }))
    await closeConnection(id)
    // Imported tokens are only useful once tried: a mirror that just
    // received the owner's material connects in the background so its
    // row (and readiness) reflect the credentials instead of sitting at
    // "needs authorization" until a session happens to use the tools.
    if (
      updated.enabled &&
      parsed.tokens !== undefined &&
      !state.locallySuppressed.has(updated.name)
    ) {
      void deps.connect(id).catch(() => undefined)
    }
  }

  const adoptOAuthOwnership: McpManager["adoptOAuthOwnership"] = async (legacyOwner) => {
    if (legacyOwner === selfServerId) return []
    const adopted: Array<string> = []
    for (const server of await run(config.db.listMcpServers)) {
      const oauth = secrets(server).oauth
      if (oauth?.tokens === undefined || oauth.refreshOwner !== legacyOwner) continue
      const updated = await replaceSecrets(server.id, (value) => ({
        ...value,
        oauth: { ...value.oauth, refreshOwner: selfServerId }
      }))
      deps.scheduleRefresh(updated, oauth.tokens)
      adopted.push(server.id)
    }
    return adopted
  }

  const subscribeCredentialsRotated: McpManager["subscribeCredentialsRotated"] = (listener) => {
    rotationListeners.add(listener)
    return () => {
      rotationListeners.delete(listener)
    }
  }

  return {
    adoptOAuthOwnership,
    importOAuthMaterial,
    oauthSyncState,
    staticSecrets,
    subscribeCredentialsRotated
  }
}

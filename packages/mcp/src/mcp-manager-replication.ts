import type { McpManagerCore } from "./mcp-manager-core.js"
import type { McpManager } from "./mcp-manager-types.js"
import type { StoredOAuth } from "./mcp-secret-store.js"

export type McpReplicationOperations = Pick<
  McpManager,
  "importOAuthMaterial" | "oauthSyncState" | "staticSecrets" | "subscribeCredentialsRotated"
>

/// The config-plane replication surface: static secrets travel as-is, OAuth
/// material travels under refresh ownership so exactly one machine rotates.
export const makeMcpReplicationOperations = (core: McpManagerCore): McpReplicationOperations => {
  const {
    closeConnection,
    record,
    refreshTimers,
    replaceSecrets,
    rotationListeners,
    secrets,
    selfServerId
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
    await replaceSecrets(id, (value) => ({
      ...value,
      oauth: { ...parsed, refreshOwner: incoming.owner }
    }))
    await closeConnection(id)
  }

  const subscribeCredentialsRotated: McpManager["subscribeCredentialsRotated"] = (listener) => {
    rotationListeners.add(listener)
    return () => {
      rotationListeners.delete(listener)
    }
  }

  return { importOAuthMaterial, oauthSyncState, staticSecrets, subscribeCredentialsRotated }
}

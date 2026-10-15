import type { McpServerRecord } from "@codevisor/db"
import type { OAuthTokens } from "@modelcontextprotocol/sdk/shared/auth.js"

import type { McpManagerCore } from "./mcp-manager-core.js"
import type { McpManager } from "./mcp-manager-types.js"
import { parseReplicatedOAuth, type StoredOAuth } from "./mcp-secret-store.js"
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
  readonly scheduleRefresh: (server: McpServerRecord, tokens: OAuthTokens) => void
  readonly connect: (id: string) => Promise<unknown>
}

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
    const parsed = parseReplicatedOAuth(incoming.material)
    if (parsed === undefined) return
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

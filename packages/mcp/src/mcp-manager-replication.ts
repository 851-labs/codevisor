import type { McpManagerCore } from "./mcp-manager-core.js"
import type { McpManager } from "./mcp-manager-types.js"
import type { McpCredentialReference } from "./mcp-oauth-grant.js"
import { run } from "./mcp-support.js"

export type McpReplicationOperations = Pick<
  McpManager,
  | "adoptOAuthOwnership"
  | "oauthCredential"
  | "setOAuthCredential"
  | "staticSecrets"
  | "subscribeCredentialsRotated"
>

export interface McpReplicationDeps {
  readonly adoptSyncedCredential: (
    id: string,
    credential: McpCredentialReference | null
  ) => Promise<void>
  readonly migrateLegacyGrant: (id: string) => Promise<McpCredentialReference | undefined>
}

export const makeMcpReplicationOperations = (
  core: McpManagerCore,
  deps: McpReplicationDeps
): McpReplicationOperations => {
  const { config, record, replaceSecrets, rotationListeners, secrets, selfServerId } = core

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

  const oauthCredential: McpManager["oauthCredential"] = async (id) => {
    const server = await record(id)
    if (server.authType !== "oauth") return undefined
    return secrets(server).oauth?.credential
  }

  const setOAuthCredential: McpManager["setOAuthCredential"] = (id, credential) =>
    deps.adoptSyncedCredential(id, credential)

  const adoptOAuthOwnership: McpManager["adoptOAuthOwnership"] = async (legacyOwner) => {
    if (legacyOwner === selfServerId) return []
    const adopted: Array<string> = []
    for (const server of await run(config.db.listMcpServers)) {
      const oauth = secrets(server).oauth
      if (oauth?.tokens === undefined || oauth.refreshOwner !== legacyOwner) continue
      await replaceSecrets(server.id, (value) => ({
        ...value,
        oauth: { ...value.oauth, refreshOwner: selfServerId }
      }))
      await deps.migrateLegacyGrant(server.id)
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
    oauthCredential,
    setOAuthCredential,
    staticSecrets,
    subscribeCredentialsRotated
  }
}

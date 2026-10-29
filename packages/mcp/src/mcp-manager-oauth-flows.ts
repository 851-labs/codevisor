import { randomUUID } from "node:crypto"

import type { McpServerRecord } from "@codevisor/db"
import { auth } from "@modelcontextprotocol/sdk/client/auth.js"
import { InvalidClientMetadataError } from "@modelcontextprotocol/sdk/server/auth/errors.js"

import { type ManagedOAuth, managedOAuthOf, managedTokenFetch } from "./mcp-managed-oauth.js"
import type { McpManagerCore } from "./mcp-manager-core.js"
import type { McpManager } from "./mcp-manager-types.js"
import type { makeMcpOAuthRuntime } from "./mcp-oauth.js"
import { reportBackgroundFailure, requireHttpUrl, run } from "./mcp-support.js"

type OAuthRuntime = ReturnType<typeof makeMcpOAuthRuntime>

export interface McpOAuthFlowDeps {
  readonly hasUsableCredential: OAuthRuntime["hasUsableCredential"]
  readonly oauthProvider: OAuthRuntime["oauthProvider"]
  readonly revokeCredential: OAuthRuntime["revokeCredential"]
  readonly validateOAuthConnection: OAuthRuntime["validateOAuthConnection"]
}

export type McpOAuthFlows = Pick<McpManager, "beginOAuth" | "disconnectOAuth" | "finishOAuth">

/* v8 ignore start */
export const makeMcpOAuthFlows = (core: McpManagerCore, deps: McpOAuthFlowDeps): McpOAuthFlows => {
  const {
    callbackUrl,
    closeConnection,
    emitCredentialsRotated,
    publicServer,
    record,
    replaceSecrets,
    saveRecord,
    secrets
  } = core
  const { state } = core
  const { hasUsableCredential, oauthProvider, revokeCredential, validateOAuthConnection } = deps

  const validateInBackground = (id: string): void => {
    void validateOAuthConnection(id).catch((cause: unknown) =>
      reportBackgroundFailure(`OAuth validation failed for MCP ${id}`, cause)
    )
  }

  const managedOAuth = (server: McpServerRecord): ManagedOAuth | undefined =>
    managedOAuthOf(core.config.catalog, core.config.managedOAuth, server)

  const adoptManagedClient = async (id: string, managed: ManagedOAuth): Promise<void> => {
    const clientId = await managed.clients.clientId(managed.client)
    await replaceSecrets(id, (value) => ({
      ...value,
      oauth: { ...value.oauth, configuredClientId: clientId, configuredClientSecret: undefined }
    }))
  }

  const beginOAuth: McpManager["beginOAuth"] = async (id, redirectBaseUrl) => {
    if (redirectBaseUrl !== undefined) state.oauthBaseUrl = redirectBaseUrl
    const server = await record(id)
    if (server.transport !== "http" || server.authType !== "oauth") {
      throw new Error("This MCP server is not configured for OAuth")
    }
    await closeConnection(id)
    if (await hasUsableCredential(id)) {
      await saveRecord(await record(id), {
        connectionState: "needsAuthorization",
        detail: undefined
      })
      validateInBackground(id)
      return new URL("/v1/mcps/oauth/complete", state.oauthBaseUrl).toString()
    }
    const managed = managedOAuth(server)
    if (managed !== undefined) await adoptManagedClient(id, managed)
    const relayed = await core.config.oauthRedirect?.(id)
    const authorizationUrl = await authorizationUrlFor(
      server,
      relayed?.redirectUrl ?? callbackUrl(),
      relayed?.state ?? `${id}.${randomUUID()}`
    ).catch((cause: unknown) => {
      if (relayed === undefined || !(cause instanceof InvalidClientMetadataError)) throw cause
      return authorizationUrlFor(server, callbackUrl(), `${id}.${randomUUID()}`)
    })
    await saveRecord(await record(id), {
      connectionState: "needsAuthorization",
      detail: undefined
    })
    return authorizationUrl
  }

  const authorizationUrlFor = async (
    server: McpServerRecord,
    redirectUrl: string,
    oauthState: string
  ): Promise<string> => {
    await replaceSecrets(server.id, (value) => ({
      ...value,
      oauth: { ...value.oauth, redirectUrl, state: oauthState }
    }))
    const provider = oauthProvider(server.id, redirectUrl)
    const result = await auth(provider, {
      serverUrl: requireHttpUrl(server.url),
      ...(server.oauthScope === undefined ? {} : { scope: server.oauthScope })
    })
    if (result !== "REDIRECT" || provider.authorizationUrl === undefined) {
      throw new Error("OAuth did not return a URL")
    }
    return provider.authorizationUrl.toString()
  }

  const serverForState = async (oauthState: string) => {
    const servers = await run(core.config.db.listMcpServers)
    const server = servers.find((candidate) => secrets(candidate).oauth?.state === oauthState)
    if (server === undefined) throw new Error("Invalid OAuth state")
    return server
  }

  const finishOAuth: McpManager["finishOAuth"] = async (oauthState, code) => {
    const server = await serverForState(oauthState)
    const id = server.id
    const managed = managedOAuth(server)
    const result = await auth(oauthProvider(id, secrets(server).oauth?.redirectUrl), {
      serverUrl: requireHttpUrl(server.url),
      authorizationCode: code,
      ...(managed === undefined ? {} : { fetchFn: managedTokenFetch(managed, fetch) }),
      ...(server.oauthScope === undefined ? {} : { scope: server.oauthScope })
    })
    if (result !== "AUTHORIZED") throw new Error("OAuth authorization did not complete")
    await replaceSecrets(id, (value) => ({
      ...value,
      oauth: { ...value.oauth, codeVerifier: undefined, state: undefined }
    }))
    await saveRecord(await record(id), {
      connectionState: "needsAuthorization",
      detail: undefined
    })
    validateInBackground(id)
    return publicServer(await record(id))
  }

  const disconnectOAuth: McpManager["disconnectOAuth"] = async (id) => {
    await closeConnection(id)
    await revokeCredential(id)
    const current = await replaceSecrets(id, (value) => ({
      ...value,
      oauth: {
        state: `${id}.${randomUUID()}`,
        credential: null,
        registrations: value.oauth?.registrations,
        discoveryState: value.oauth?.discoveryState,
        configuredClientId: value.oauth?.configuredClientId,
        configuredClientSecret: value.oauth?.configuredClientSecret
      }
    }))
    emitCredentialsRotated(id)
    return publicServer(
      await saveRecord(current, {
        connectionState: "needsAuthorization",
        toolCount: 0,
        detail: undefined
      })
    )
  }

  return { beginOAuth, disconnectOAuth, finishOAuth }
}
/* v8 ignore stop */

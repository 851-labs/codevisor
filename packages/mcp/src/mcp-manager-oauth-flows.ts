import { auth } from "@modelcontextprotocol/sdk/client/auth.js"
import { randomUUID } from "node:crypto"
import type { McpManagerCore } from "./mcp-manager-core.js"
import type { McpManager } from "./mcp-manager-types.js"
import type { makeMcpOAuthRuntime } from "./mcp-oauth.js"
import { reportBackgroundFailure, requireHttpUrl } from "./mcp-support.js"

type OAuthRuntime = ReturnType<typeof makeMcpOAuthRuntime>

export interface McpOAuthFlowDeps {
  readonly oauthProvider: OAuthRuntime["oauthProvider"]
  readonly validateOAuthConnection: OAuthRuntime["validateOAuthConnection"]
}

export type McpOAuthFlows = Pick<McpManager, "beginOAuth" | "disconnectOAuth" | "finishOAuth">

/* v8 ignore start -- browser OAuth lifecycle is covered by the live provider integration flow. */
/// The interactive OAuth authorization flow: begin (redirect to the
/// provider), finish (exchange the code), and disconnect (drop tokens).
export const makeMcpOAuthFlows = (core: McpManagerCore, deps: McpOAuthFlowDeps): McpOAuthFlows => {
  const {
    callbackUrl,
    closeConnection,
    publicServer,
    record,
    replaceSecrets,
    saveRecord,
    secrets
  } = core
  const { state } = core
  const { oauthProvider, validateOAuthConnection } = deps

  const beginOAuth: McpManager["beginOAuth"] = async (id, redirectBaseUrl) => {
    if (redirectBaseUrl !== undefined) state.oauthBaseUrl = redirectBaseUrl
    const server = await record(id)
    if (server.transport !== "http" || server.authType !== "oauth") {
      throw new Error("This MCP server is not configured for OAuth")
    }
    await closeConnection(id)
    const redirectUrl = callbackUrl()
    const oauthState = `${id}.${randomUUID()}`
    await replaceSecrets(id, (value) => ({
      ...value,
      oauth: { ...value.oauth, redirectUrl, state: oauthState }
    }))
    const provider = oauthProvider(id, redirectUrl)
    const result = await auth(provider, {
      serverUrl: requireHttpUrl(server.url),
      ...(server.oauthScope === undefined ? {} : { scope: server.oauthScope })
    })
    if (result === "AUTHORIZED") {
      await saveRecord(await record(id), {
        connectionState: "needsAuthorization",
        detail: undefined
      })
      void validateOAuthConnection(id).catch((cause: unknown) =>
        reportBackgroundFailure(`OAuth validation failed for MCP ${id}`, cause)
      )
      return new URL("/v1/mcps/oauth/complete", state.oauthBaseUrl).toString()
    }
    if (provider.authorizationUrl === undefined) throw new Error("OAuth did not return a URL")
    await saveRecord(await record(id), {
      connectionState: "needsAuthorization",
      detail: undefined
    })
    return provider.authorizationUrl.toString()
  }

  const finishOAuth: McpManager["finishOAuth"] = async (oauthState, code) => {
    const id = oauthState.split(".", 1)[0]
    if (id === undefined || id.length === 0) throw new Error("Invalid OAuth state")
    const server = await record(id)
    const expected = secrets(server).oauth?.state
    if (expected === undefined || expected !== oauthState) throw new Error("Invalid OAuth state")
    const result = await auth(oauthProvider(id, secrets(server).oauth?.redirectUrl), {
      serverUrl: requireHttpUrl(server.url),
      authorizationCode: code,
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
    void validateOAuthConnection(id).catch((cause: unknown) =>
      reportBackgroundFailure(`OAuth validation failed for MCP ${id}`, cause)
    )
    return publicServer(await record(id))
  }

  const disconnectOAuth: McpManager["disconnectOAuth"] = async (id) => {
    await closeConnection(id)
    const current = await replaceSecrets(id, (value) => ({
      ...value,
      oauth: {
        state: `${id}.${randomUUID()}`,
        configuredClientId: value.oauth?.configuredClientId,
        configuredClientSecret: value.oauth?.configuredClientSecret
      }
    }))
    // Dropping tokens is an auth action, not a disable: the enabled wish
    // is left alone so the fleet definition never flips underneath it.
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

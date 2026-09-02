import { isInitializeRequest } from "@modelcontextprotocol/sdk/types.js"
import { randomBytes, timingSafeEqual } from "node:crypto"
import type { makeMcpGateway } from "./mcp-gateway.js"
import type { McpManagerCore } from "./mcp-manager-core.js"
import type { McpManager } from "./mcp-manager-types.js"
import { readJsonBody } from "./mcp-support.js"

type GatewayHandles = ReturnType<typeof makeMcpGateway>

export interface McpGatewayOperationDeps {
  readonly createGatewayConnection: GatewayHandles["createGatewayConnection"]
  readonly gatewayRuntime: GatewayHandles["gatewayRuntime"]
  readonly unsubscribePluginTools: (() => void) | undefined
}

export type McpGatewayOperations = Pick<
  McpManager,
  "close" | "closeSession" | "handleGatewayRequest" | "issueGateway"
>

/// Per-session tool gateways: issuing credentials, routing gateway HTTP
/// traffic to the right MCP connection, and tearing everything down.
export const makeMcpGatewayOperations = (
  core: McpManagerCore,
  deps: McpGatewayOperationDeps
): McpGatewayOperations => {
  const {
    automationProviders,
    browserSetupBroker,
    builtinsReady,
    closeConnection,
    connections,
    gatewayBearerToken,
    gateways,
    refreshTimers,
    sessionGatewayIds,
    state
  } = core
  const { createGatewayConnection, gatewayRuntime, unsubscribePluginTools } = deps

  const issueGateway: McpManager["issueGateway"] = async (sessionId, projectId, sink) => {
    await builtinsReady
    if (sink !== undefined) {
      browserSetupBroker.setSink(sessionId, sink)
    }
    const existingId = sessionGatewayIds.get(sessionId)
    if (existingId !== undefined && gateways.has(existingId)) {
      const existingUrl = new URL("/mcp/gateway", state.gatewayBaseUrl)
      existingUrl.searchParams.set("gateway", existingId)
      return { name: "codevisor", url: existingUrl.toString(), bearerToken: gatewayBearerToken }
    }
    const gatewayId = randomBytes(24).toString("base64url")
    const runtime = await gatewayRuntime(sessionId, projectId)
    gateways.set(gatewayId, runtime)
    sessionGatewayIds.set(sessionId, gatewayId)
    const url = new URL("/mcp/gateway", state.gatewayBaseUrl)
    url.searchParams.set("gateway", gatewayId)
    return {
      name: "codevisor",
      url: url.toString(),
      bearerToken: gatewayBearerToken
    }
  }

  const closeSession: McpManager["closeSession"] = async (sessionId) => {
    const gatewayId = sessionGatewayIds.get(sessionId)
    sessionGatewayIds.delete(sessionId)
    if (gatewayId !== undefined) {
      const gateway = gateways.get(gatewayId)
      gateways.delete(gatewayId)
      await Promise.all(
        [...(gateway?.connections.values() ?? [])].map((connection) =>
          connection.server.close().catch(() => undefined)
        )
      )
    }
    await Promise.all(
      [...automationProviders.values()].map((provider) => provider.closeSession(sessionId))
    )
    await browserSetupBroker.closeSession(sessionId)
  }

  const handleGatewayRequest: McpManager["handleGatewayRequest"] = async (request, response) => {
    const authorization = request.headers.authorization
    const token = authorization?.startsWith("Bearer ") ? authorization.slice(7) : undefined
    const authorized =
      token !== undefined &&
      token.length === gatewayBearerToken.length &&
      timingSafeEqual(Buffer.from(token), Buffer.from(gatewayBearerToken))
    if (!authorized) {
      response.writeHead(401, { "content-type": "application/json" })
      response.end(JSON.stringify({ error: "Invalid Codevisor tool gateway token" }))
      return
    }
    /* v8 ignore next -- Node HTTP requests always carry a URL. */
    const gatewayId = new URL(request.url ?? "/", state.gatewayBaseUrl).searchParams.get("gateway")
    /* v8 ignore next -- missing and unknown gateway capabilities share the tested 404 response. */
    const runtime = gatewayId === null ? undefined : gateways.get(gatewayId)
    if (runtime === undefined) {
      response.writeHead(404, { "content-type": "application/json" })
      response.end(JSON.stringify({ error: "Codevisor tool gateway session not found" }))
      return
    }

    // Route follow-up requests to their existing MCP connection. (Node
    // folds duplicate non-set-cookie headers into one string, so the
    // header is a string or absent — never an array.)
    const sessionHeader = request.headers["mcp-session-id"]
    const mcpSessionId = typeof sessionHeader === "string" ? sessionHeader : undefined
    const existing = mcpSessionId === undefined ? undefined : runtime.connections.get(mcpSessionId)
    if (existing !== undefined) {
      await existing.transport.handleRequest(request, response)
      return
    }
    if (mcpSessionId !== undefined) {
      // A session id we no longer know (e.g. a connection from before a
      // server restart). 404 tells spec-following clients to re-initialize.
      response.writeHead(404, { "content-type": "application/json" })
      response.end(JSON.stringify({ error: "Unknown MCP session — re-initialize" }))
      return
    }

    // No session id: only a fresh `initialize` may open a new connection.
    // Harnesses re-initialize mid-session (codex 0.145+ rebuilds its MCP
    // connections on account/plugin changes), so every handshake gets its
    // own server + transport pair for the lifetime of that MCP session.
    if (request.method !== "POST") {
      response.writeHead(405, { "content-type": "application/json" })
      response.end(JSON.stringify({ error: "Method not allowed without an MCP session" }))
      return
    }
    let body: unknown
    try {
      body = await readJsonBody(request)
    } catch {
      response.writeHead(400, { "content-type": "application/json" })
      response.end(JSON.stringify({ error: "Invalid JSON body" }))
      return
    }
    const isInitialize = Array.isArray(body)
      ? body.some((entry) => isInitializeRequest(entry))
      : isInitializeRequest(body)
    if (!isInitialize) {
      response.writeHead(400, { "content-type": "application/json" })
      response.end(JSON.stringify({ error: "Send an initialize request to open an MCP session" }))
      return
    }
    const connection = await createGatewayConnection(runtime)
    await connection.transport.handleRequest(request, response, body)
  }

  const close: McpManager["close"] = async () => {
    unsubscribePluginTools?.()
    /* v8 ignore next -- timers only exist for the live OAuth refresh adapter. */
    for (const timer of refreshTimers.values()) clearTimeout(timer)
    await Promise.all([...connections.keys()].map(closeConnection))
    await browserSetupBroker.close()
    await Promise.all([...automationProviders.values()].map((provider) => provider.close()))
    await Promise.all(
      [...gateways.values()].flatMap((gateway) =>
        [...gateway.connections.values()].map(async (connection) => {
          /* v8 ignore next -- best-effort cleanup; normal gateway shutdown resolves cleanly. */
          await connection.server.close().catch(() => undefined)
        })
      )
    )
    gateways.clear()
    sessionGatewayIds.clear()
  }

  return { close, closeSession, handleGatewayRequest, issueGateway }
}

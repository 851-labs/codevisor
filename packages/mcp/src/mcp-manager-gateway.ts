import { randomBytes, timingSafeEqual } from "node:crypto"

import { isInitializeRequest } from "@modelcontextprotocol/sdk/types.js"

import type { ExecutionJobs } from "./mcp-gateway-jobs.js"
import type { makeMcpGateway } from "./mcp-gateway.js"
import type { McpManagerCore } from "./mcp-manager-core.js"
import type { McpManager } from "./mcp-manager-types.js"
import { readJsonBody } from "./mcp-support.js"

type GatewayHandles = ReturnType<typeof makeMcpGateway>

export interface McpGatewayOperationDeps {
  readonly createGatewayConnection: GatewayHandles["createGatewayConnection"]
  readonly finishRemoteBrowserTurn: GatewayHandles["finishRemoteBrowserTurn"]
  readonly gatewayRuntime: GatewayHandles["gatewayRuntime"]
  readonly invokeRemoteGatewayCall: GatewayHandles["invokeRemoteGatewayCall"]
  readonly jobs: ExecutionJobs
  readonly unsubscribeSkills: (() => void) | undefined
}

export type McpGatewayOperations = Pick<
  McpManager,
  | "close"
  | "closeSession"
  | "beginTurn"
  | "finishTurn"
  | "handleGatewayRequest"
  | "invokeRemoteGatewayCall"
  | "issueGateway"
>

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
    oauthRetries,
    sessionGatewayIds,
    state,
    turnClientIds
  } = core
  const {
    createGatewayConnection,
    finishRemoteBrowserTurn,
    gatewayRuntime,
    invokeRemoteGatewayCall,
    jobs,
    unsubscribeSkills
  } = deps

  const issueGateway: McpManager["issueGateway"] = async (sessionId, projectId, sink) => {
    await builtinsReady
    if (sink !== undefined) {
      browserSetupBroker.setSink(sessionId, sink)
    }
    const existingId = sessionGatewayIds.get(sessionId)
    const existing = existingId === undefined ? undefined : gateways.get(existingId)
    if (existingId !== undefined && existing !== undefined) {
      if (sink !== undefined) existing.sink = sink
      const existingUrl = new URL("/mcp/gateway", state.gatewayBaseUrl)
      existingUrl.searchParams.set("gateway", existingId)
      return {
        name: "codevisor",
        url: existingUrl.toString(),
        bearerToken: gatewayBearerToken
      }
    }
    const gatewayId = randomBytes(24).toString("base64url")
    const runtime = await gatewayRuntime(sessionId, projectId)
    runtime.sink = sink
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
    turnClientIds.delete(sessionId)
    jobs.cancelSession(sessionId)
    if (gatewayId !== undefined) {
      const gateway = gateways.get(gatewayId)
      gateways.delete(gatewayId)
      await Promise.all(
        [...(gateway?.connections.values() ?? [])].map((connection) =>
          connection.server.close().catch(() => undefined)
        )
      )
    }
    await Promise.all([
      ...[...automationProviders.values()].map((provider) => provider.closeSession(sessionId)),
      finishRemoteBrowserTurn(sessionId)
    ])
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
    /* v8 ignore next */
    const gatewayId = new URL(request.url ?? "/", state.gatewayBaseUrl).searchParams.get("gateway")
    /* v8 ignore next */
    const runtime = gatewayId === null ? undefined : gateways.get(gatewayId)
    if (runtime === undefined) {
      response.writeHead(404, { "content-type": "application/json" })
      response.end(JSON.stringify({ error: "Codevisor tool gateway session not found" }))
      return
    }

    const sessionHeader = request.headers["mcp-session-id"]
    const mcpSessionId = typeof sessionHeader === "string" ? sessionHeader : undefined
    const existing = mcpSessionId === undefined ? undefined : runtime.connections.get(mcpSessionId)
    if (existing !== undefined) {
      await existing.transport.handleRequest(request, response)
      return
    }
    if (mcpSessionId !== undefined) {
      response.writeHead(404, { "content-type": "application/json" })
      response.end(JSON.stringify({ error: "Unknown MCP session — re-initialize" }))
      return
    }

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
    unsubscribeSkills?.()
    for (const cancel of oauthRetries.values()) cancel()
    oauthRetries.clear()
    await Promise.all([...connections.keys()].map(closeConnection))
    await browserSetupBroker.close()
    await Promise.all([...automationProviders.values()].map((provider) => provider.close()))
    await Promise.all(
      [...gateways.values()].flatMap((gateway) =>
        [...gateway.connections.values()].map(async (connection) => {
          /* v8 ignore next */
          await connection.server.close().catch(() => undefined)
        })
      )
    )
    gateways.clear()
    sessionGatewayIds.clear()
    turnClientIds.clear()
  }

  const finishTurn = async (sessionId: string) => {
    await Promise.all([
      ...[...automationProviders.values()].map((provider) => provider.finishTurn?.(sessionId)),
      finishRemoteBrowserTurn(sessionId),
      browserSetupBroker.finishTurn(sessionId)
    ])
  }
  const beginTurn: McpManager["beginTurn"] = async (sessionId, options) => {
    if (options?.clientId === undefined) turnClientIds.delete(sessionId)
    else turnClientIds.set(sessionId, options.clientId)
    await builtinsReady
    await browserSetupBroker.beginTurn(
      sessionId,
      options?.clientPlatform === undefined ? {} : { clientPlatform: options.clientPlatform }
    )
  }
  return {
    close,
    closeSession,
    beginTurn,
    finishTurn,
    handleGatewayRequest,
    invokeRemoteGatewayCall,
    issueGateway
  }
}

import type { ServerResponse } from "node:http"
import { hostname } from "node:os"

import { HttpFailure, run, writeJson } from "../server-context.js"
import type { CodevisorServerConfig } from "../server-context.js"
import { liveCloudDeviceId } from "./cloud.js"
import { isMethodRoute, respondAfter } from "./route-context.js"
import type { RouteContext, RouteHandler } from "./route-context.js"

export const accountGatewayRouteFor = ({ url }: RouteContext): RouteHandler | undefined => {
  if (url.pathname === "/harness/provider-token") return forwardProviderToken
  if (url.pathname.startsWith("/harness/claude/")) return forwardClaudeGateway
  return undefined
}

export const publicRouteFor = ({ request, url }: RouteContext): RouteHandler | undefined => {
  if (isMethodRoute(request, url, "GET", "/v1/health")) return writeHealth
  if (isMethodRoute(request, url, "GET", "/v1/discovery")) return writeDiscovery
  if (url.pathname === "/mcp/gateway") return forwardMcpGateway
  return undefined
}

export const mcpOAuthRouteFor = ({ request, url }: RouteContext): RouteHandler | undefined => {
  if (isMethodRoute(request, url, "GET", "/v1/mcps/oauth/callback")) return finishMcpOAuth
  if (isMethodRoute(request, url, "GET", "/v1/mcps/oauth/complete")) return writeOAuthReconnecting
  return undefined
}

interface DiscoveredMachine {
  readonly name: string
  readonly kind: CodevisorServerConfig["kind"]
  readonly version: string
  readonly platform: NodeJS.Platform
  readonly hostname: string
  readonly cloudLinked: boolean
}

interface OAuthCallbackQuery {
  readonly state: string | null
  readonly code: string | null
}

interface OAuthCallback {
  readonly state: string
  readonly code: string
}

const accountGatewayUnavailable = "Account gateway unavailable"

const mcpGatewayUnavailable = "MCP gateway unavailable"

const oauthAuthorizedPage =
  "<!doctype html><title>Codevisor</title><p>Authorization complete. Codevisor is connecting to the MCP server. You can close this window.</p>"

const oauthReconnectingPage =
  "<!doctype html><title>Codevisor</title><p>Codevisor is reconnecting to the MCP server. You can close this window.</p>"

const forwardProviderToken = ({ services, request, response }: RouteContext): Promise<void> => {
  if (!services.sharedAccounts) throw new HttpFailure(501, accountGatewayUnavailable)
  return respondAfter(response, services.sharedAccounts.providers.runtime.handle(request, response))
}

const forwardClaudeGateway = ({
  services,
  request,
  response,
  url
}: RouteContext): Promise<void> => {
  if (!services.sharedAccounts) throw new HttpFailure(501, accountGatewayUnavailable)
  return respondAfter(response, services.sharedAccounts.gateway.handle(request, response, url))
}

const writeHealth = ({ config, response }: RouteContext): void =>
  writeJson(response, 200, {
    ok: true,
    version: config.version,
    database: "ready",
    bootId: config.bootId,
    processId: config.processId,
    appOwned: config.appOwned,
    buildNumber: config.buildNumber,
    sourceRevision: config.sourceRevision,
    serviceManaged: config.serviceManaged
  })

const writeDiscovery = ({ services, config, response }: RouteContext): Promise<void> => {
  const serverId = config.id
  return respondAfter(response, run(services.db.getOrCreateInstanceId), (machineId) =>
    writeJson(response, 200, { serverId, machineId, ...discoveredMachine(config) })
  )
}

const discoveredMachine = (config: CodevisorServerConfig): DiscoveredMachine => ({
  name: config.name,
  kind: config.kind,
  version: config.version,
  platform: process.platform,
  hostname: hostname(),
  cloudLinked: liveCloudDeviceId(config) !== undefined
})

const forwardMcpGateway = ({ services, request, response }: RouteContext): Promise<void> => {
  if (services.mcp === undefined) throw new HttpFailure(501, mcpGatewayUnavailable)
  return respondAfter(response, services.mcp.handleGatewayRequest(request, response))
}

const finishMcpOAuth = ({ services, response, url }: RouteContext): Promise<void> => {
  if (services.mcp === undefined) throw new HttpFailure(501, mcpGatewayUnavailable)
  const callback = oauthCallbackQuery(url)
  if (!hasCallbackData(callback)) throw new HttpFailure(400, "Missing OAuth callback data")

  return respondAfter(response, services.mcp.finishOAuth(callback.state, callback.code), () =>
    writeHtml(response, oauthAuthorizedPage)
  )
}

const oauthCallbackQuery = (url: URL): OAuthCallbackQuery => ({
  state: url.searchParams.get("state"),
  code: url.searchParams.get("code")
})

const hasCallbackData = (callback: OAuthCallbackQuery): callback is OAuthCallback =>
  !(callback.state === null || callback.code === null)

const writeOAuthReconnecting = ({ response }: RouteContext): void =>
  writeHtml(response, oauthReconnectingPage)

const writeHtml = (response: ServerResponse, page: string): void => {
  response.writeHead(200, { "content-type": "text/html; charset=utf-8" })
  response.end(page)
}

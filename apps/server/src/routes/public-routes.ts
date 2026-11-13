import type { ServerResponse } from "node:http"
import { hostname } from "node:os"

import { gitInstallation } from "@codevisor/worktrees"

import { HttpFailure, run, writeJson } from "../server-context.js"
import type { CodevisorServerConfig } from "../server-context.js"
import { liveCloudDeviceId } from "./cloud.js"
import { appScheme, appSchemeParameter, oauthFinishedPage } from "./oauth-returns.js"
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
  if (isMethodRoute(request, url, "GET", "/v1/plugins/oauth/callback")) return finishPluginOAuth
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
  readonly issuer: string | null
}

interface OAuthCallback {
  readonly state: string
  readonly code: string
  readonly issuer: string | null
}

const accountGatewayUnavailable = "Account gateway unavailable"

const mcpGatewayUnavailable = "MCP gateway unavailable"

const oauthAuthorizedMessage =
  "Authorization complete. Codevisor is connecting to the MCP server. You can close this window."

const oauthReconnectingMessage =
  "Codevisor is reconnecting to the MCP server. You can close this window."

const pluginSignedInMessage = "Signed in. You can return to Codevisor."

const finishPluginOAuth = ({
  services,
  routeState,
  response,
  url
}: RouteContext): Promise<void> => {
  const platform = services.pluginPlatform
  if (platform === undefined) throw new HttpFailure(501, "Plugins unavailable")
  const state = url.searchParams.get("state") ?? ""
  const code = url.searchParams.get("code") ?? undefined
  const completing = platform.accounts.completeOAuth(
    state,
    code,
    url.searchParams.get("error") ?? undefined
  )
  const app = routeState.oauthReturns.take(state)
  return respondAfter(response, completing, () =>
    writeHtml(response, oauthFinishedPage(pluginSignedInMessage, app))
  )
}

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

const writeHealth = ({ config, response }: RouteContext): Promise<void> =>
  respondAfter(response, gitInstallation(), (git) =>
    writeJson(response, 200, {
      ok: true,
      version: config.version,
      database: "ready",
      git: git.state,
      bootId: config.bootId,
      processId: config.processId,
      appOwned: config.appOwned,
      buildNumber: config.buildNumber,
      sourceRevision: config.sourceRevision,
      serviceManaged: config.serviceManaged
    })
  )

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

const finishMcpOAuth = ({ services, routeState, response, url }: RouteContext): Promise<void> => {
  if (services.mcp === undefined) throw new HttpFailure(501, mcpGatewayUnavailable)
  const callback = oauthCallbackQuery(url)
  if (!hasCallbackData(callback)) throw new HttpFailure(400, "Missing OAuth callback data")

  const app = routeState.oauthReturns.take(callback.state)
  return respondAfter(
    response,
    services.mcp.finishOAuth(callback.state, callback.code, callback.issuer ?? undefined),
    () => writeHtml(response, oauthFinishedPage(oauthAuthorizedMessage, app))
  )
}

const oauthCallbackQuery = (url: URL): OAuthCallbackQuery => ({
  state: url.searchParams.get("state"),
  code: url.searchParams.get("code"),
  issuer: url.searchParams.get("iss")
})

const hasCallbackData = (callback: OAuthCallbackQuery): callback is OAuthCallback =>
  !(callback.state === null || callback.code === null)

const writeOAuthReconnecting = ({ response, url }: RouteContext): void =>
  writeHtml(
    response,
    oauthFinishedPage(oauthReconnectingMessage, appScheme(url.searchParams.get(appSchemeParameter)))
  )

const writeHtml = (response: ServerResponse, page: string): void => {
  response.writeHead(200, { "content-type": "text/html; charset=utf-8" })
  response.end(page)
}

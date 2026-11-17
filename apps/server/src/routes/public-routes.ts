import type { ServerResponse } from "node:http"
import { hostname } from "node:os"

import { gitInstallation } from "@codevisor/worktrees"

import { HttpFailure, matchRoute, run, writeJson } from "../server-context.js"
import type { CodevisorServerConfig } from "../server-context.js"
import { liveCloudDeviceId } from "./cloud.js"
import { appScheme, appSchemeParameter, oauthFinishedPage, signInPage } from "./oauth-returns.js"
import { isMethodRoute, respondAfter } from "./route-context.js"
import type { RouteContext, RouteHandler } from "./route-context.js"
import { signInTicket } from "./sign-in-handoffs.js"

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
  if (request.method !== "GET") return undefined
  if (matchRoute(url.pathname, "/v1/sign-in/:ticket") !== undefined) return writeSignInStarting
  if (matchRoute(url.pathname, "/v1/sign-in/:ticket/continue") !== undefined) return continueSignIn
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

const signInNotFinishedMessage = "Sign-in wasn’t finished. You can return to Codevisor."

const signInFailedPrefix = "Sign-in didn’t finish."

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
  return writeSignInResult(response, completing, pluginSignedInMessage, app)
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

const finishMcpOAuth = async ({
  services,
  routeState,
  response,
  url
}: RouteContext): Promise<void> => {
  if (services.mcp === undefined) throw new HttpFailure(501, mcpGatewayUnavailable)
  const callback = oauthCallbackQuery(url)
  const app = callback.state === null ? undefined : routeState.oauthReturns.take(callback.state)
  if (!hasCallbackData(callback)) {
    if (app === undefined) throw new HttpFailure(400, "Missing OAuth callback data")
    return writeHtml(response, oauthFinishedPage(signInNotFinishedMessage, app))
  }

  return writeSignInResult(
    response,
    services.mcp.finishOAuth(callback.state, callback.code, callback.issuer ?? undefined),
    oauthAuthorizedMessage,
    app
  )
}

const writeSignInResult = async (
  response: ServerResponse,
  finishing: Promise<unknown>,
  finishedMessage: string,
  app: string | undefined
): Promise<void> => {
  if (app === undefined) {
    return respondAfter(response, finishing, () =>
      writeHtml(response, oauthFinishedPage(finishedMessage, app))
    )
  }
  const failure = await finishing.then(
    () => undefined,
    (cause: unknown) => errorMessage(cause)
  )
  const message = failure === undefined ? finishedMessage : `${signInFailedPrefix} ${failure}`
  writeHtml(response, oauthFinishedPage(message, app))
}

const writeSignInStarting = ({ response, url }: RouteContext): void => {
  const ticket = signInTicket(matchRoute(url.pathname, "/v1/sign-in/:ticket"))
  if (ticket === undefined) throw new HttpFailure(404, "Route not found")

  const next = new URL(`/v1/sign-in/${ticket}/continue`, url)
  const app = appScheme(url.searchParams.get(appSchemeParameter))
  if (app !== undefined) next.searchParams.set(appSchemeParameter, app)
  const name = url.searchParams.get("name")?.slice(0, 80)
  writeHtml(
    response,
    signInPage({
      title: name ? `Signing in to ${name}…` : "Signing in…",
      message: name ? `Opening ${name} sign-in…` : "Opening sign-in…",
      continuesAt: `${next.pathname}${next.search}`
    })
  )
}

const continueSignIn = async ({ routeState, response, url }: RouteContext): Promise<void> => {
  const ticket = signInTicket(matchRoute(url.pathname, "/v1/sign-in/:ticket/continue"))
  if (ticket === undefined) throw new HttpFailure(404, "Route not found")

  const handoff = await routeState.signInHandoffs.wait(ticket)
  if ("failure" in handoff) {
    const app = appScheme(url.searchParams.get(appSchemeParameter))
    return writeHtml(response, oauthFinishedPage(`${signInFailedPrefix} ${handoff.failure}`, app))
  }
  response.writeHead(302, { location: handoff.authorizationUrl, "cache-control": "no-store" })
  response.end()
}

const errorMessage = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

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

import type { IncomingMessage, ServerResponse } from "node:http"

import { isBrowserProxyRequest } from "./infra/browser-forward-proxy.js"
import { routeAutoResume } from "./routes/auto-resume-routes.js"
import { routeBots } from "./routes/bots.js"
import { routeBrowserState } from "./routes/browser-state.js"
import { routeBrowserUse } from "./routes/browser-use.js"
import { routeClientControl } from "./routes/client-control.js"
import { routeCloud } from "./routes/cloud.js"
import { routeFiles } from "./routes/files.js"
import { routeFs } from "./routes/fs.js"
import { routeGatewayInvoke } from "./routes/gateway-invoke.js"
import { routeGitAuth } from "./routes/git-auth.js"
import { routeHarnesses } from "./routes/harnesses.js"
import { routeLinkPreviews } from "./routes/link-previews.js"
import { routeMachineStats } from "./routes/machine-stats.js"
import { routeMachineMcps } from "./routes/mcp-machine.js"
import { routeMcps, routeMcpScopes, routeNativeMcps } from "./routes/mcps.js"
import { routeNetDirect } from "./routes/net-direct.js"
import { routePluginProxy, routePlugins } from "./routes/plugins.js"
import { routeProjects } from "./routes/projects.js"
import { accountGatewayRouteFor, mcpOAuthRouteFor, publicRouteFor } from "./routes/public-routes.js"
import type { RouteContext, RouteFamily } from "./routes/route-context.js"
import { routeScreenSharing } from "./routes/screen-sharing.js"
import { firstAuthorizedRouteFor, serverEndpointFor } from "./routes/server-endpoints.js"
import { routeSessionEvents } from "./routes/session-event-routes.js"
import { routeSessions } from "./routes/sessions.js"
import { routeSimulators } from "./routes/simulators.js"
import { routeSkills } from "./routes/skills.js"
import { configMutationNamespace, runBackgroundSyncReconcile } from "./routes/sync-reconcilers.js"
import { routeSync } from "./routes/sync.js"
import { routeTerminals } from "./routes/terminals.js"
import { routeToolIcons } from "./routes/tool-icons.js"
import { routeTranscriptStress } from "./routes/transcript-stress.js"
import { routeWorkspaces } from "./routes/workspaces.js"
import { authorize, HttpFailure, parseRequestUrl, writeFailure } from "./server-context.js"
import type {
  CodevisorServerConfig,
  CodevisorServerServices,
  EventFanout,
  RouteState
} from "./server-context.js"

export const handleRequest = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse
): Promise<void> => {
  try {
    if (isBrowserProxyRequest(request)) return forwardToBrowserProxy(routeState, request, response)

    const url = parseRequestUrl(request)
    const route: RouteContext = { services, fanout, routeState, request, response, url, config }
    const gatewayRoute = accountGatewayRouteFor(route)
    if (gatewayRoute !== undefined) return gatewayRoute(route)

    reconcileAfterConfigMutation(route)
    const publicRoute = publicRouteFor(route)
    if (publicRoute !== undefined) return publicRoute(route)

    if (isPluginPath(url) && (await routePluginProxy(services, request, response, url))) return

    const oauthRoute = mcpOAuthRouteFor(route)
    if (oauthRoute !== undefined) return oauthRoute(route)

    const firstAuthorizedRoute = firstAuthorizedRouteFor(route)
    await authorize(services.db, config, request)
    if (firstAuthorizedRoute !== undefined) return firstAuthorizedRoute(route)

    for (const routeFamily of featureRouteFamilies) {
      if (await routeFamily(route)) return
    }

    const endpoint = serverEndpointFor(route)
    if (endpoint !== undefined) return endpoint(route)

    for (const routeFamily of resourceRouteFamilies) {
      if (await routeFamily(route)) return
    }

    if (routeNetDirect(config, request, response, url)) return
    if (await routeTerminals(services, request, response, url)) return

    throw new HttpFailure(404, "Route not found")
  } catch (cause) {
    writeFailure(response, cause)
  }
}

const featureRouteFamilies: ReadonlyArray<RouteFamily> = [
  ({ services, fanout, routeState, request, response, url }) =>
    routeTranscriptStress(services, fanout, routeState, request, response, url),
  ({ services, config, request, response, url }) =>
    routeScreenSharing(services, config, request, response, url),
  ({ config, request, response, url }) => routeSimulators(config, request, response, url),
  ({ services, request, response, url }) => routeBrowserState(services, request, response, url)
]

const resourceRouteFamilies: ReadonlyArray<RouteFamily> = [
  ({ services, request, response, url }) => routeGatewayInvoke(services, request, response, url),
  ({ services, config, fanout, request, response, url }) =>
    routeProjects(services, config, fanout, request, response, url),
  ({ services, request, response, url }) => routeGitAuth(services, request, response, url),
  ({ routeState, config, request, response, url }) =>
    routeClientControl(routeState.clientControl, config, request, response, url),
  routeWorkspaces,
  ({ services, config, fanout, routeState, request, response, url }) =>
    routeBots(services, config, fanout, routeState, request, response, url),
  routeHarnesses,
  ({ services, request, response, url }) => routeBrowserUse(services, request, response, url),
  ({ services, config, fanout, request, response, url }) =>
    routeMachineMcps(services, config, fanout, request, response, url),
  ({ services, request, response, url }) => routeToolIcons(services, request, response, url),
  ({ services, request, response, url }) => routeLinkPreviews(services, request, response, url),
  ({ services, request, response, url }) => routeMachineStats(services, request, response, url),
  ({ services, request, response, url }) => routeMcps(services, request, response, url),
  ({ services, request, response, url }) => routeMcpScopes(services, request, response, url),
  ({ services, request, response, url }) => routeNativeMcps(services, request, response, url),
  ({ services, request, response, url }) => routeSkills(services, request, response, url),
  routeSync,
  routePlugins,
  ({ services, request, response, url }) => routeSessionEvents(services, request, response, url),
  ({ routeState, request, response, url }) => routeAutoResume(routeState, request, response, url),
  routeSessions,
  ({ services, request, response, url }) => routeFiles(services, request, response, url),
  ({ services, request, response, url }) => routeFs(services, request, response, url),
  ({ config, request, response, url }) => routeCloud(config, request, response, url)
]

const forwardToBrowserProxy = (
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse
): void => {
  if (routeState.browserProxy) routeState.browserProxy.handleHTTP(request, response)
  else response.writeHead(501).end()
}

const reconcileAfterConfigMutation = ({
  services,
  config,
  fanout,
  request,
  response,
  url
}: RouteContext): void => {
  const mutatedPlane = configMutationNamespace(request.method, url.pathname)
  if (mutatedPlane === undefined) return

  response.once("finish", () => {
    if (response.statusCode < 400)
      void runBackgroundSyncReconcile(services, config, fanout, mutatedPlane)
  })
}

const isPluginPath = (url: URL): boolean => url.pathname.startsWith("/v1/plugins/")

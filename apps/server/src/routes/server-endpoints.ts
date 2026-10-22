import type { ServerResponse } from "node:http"
import { hostname } from "node:os"

import { makeOpenApiDocument, MAX_UPLOAD_BYTES } from "@codevisor/api"

import { HttpFailure, run, writeJson } from "../server-context.js"
import type { CodevisorServerConfig, CodevisorServerServices } from "../server-context.js"
import { liveCloudDeviceId } from "./cloud.js"
import { handleEvents } from "./events.js"
import { discoverCapabilities } from "./harnesses.js"
import { isMethodRoute, respondAfter } from "./route-context.js"
import type { RouteContext, RouteHandler } from "./route-context.js"
import { simulatorsAvailable } from "./simulators.js"
import { restartRouteFor, updateRouteFor } from "./update-routes.js"

export const firstAuthorizedRouteFor = ({
  request,
  url
}: RouteContext): RouteHandler | undefined => {
  if (isMethodRoute(request, url, "GET", "/v1/navigation")) return writeNavigation
  if (isMethodRoute(request, url, "GET", "/v1/events")) return streamEvents
  return undefined
}

export const serverEndpointFor = (route: RouteContext): RouteHandler | undefined =>
  proxySessionRouteFor(route) ??
  eventCursorRouteFor(route) ??
  serverInfoRouteFor(route) ??
  updateRouteFor(route) ??
  restartRouteFor(route) ??
  connectionRouteFor(route)

interface InfoHead {
  readonly cloudDeviceId: string | undefined
  readonly identity: ServerIdentity
  readonly features: ReadonlyArray<string>
}

interface MachineDetails {
  readonly arch: NodeJS.Architecture
  readonly hostname: string
  readonly maxUploadBytes: number
  readonly icon?: string
  readonly cloudDeviceId?: string
}

interface ServerIdentity {
  readonly id: string
  readonly name: string
  readonly kind: CodevisorServerConfig["kind"]
  readonly version: string
  readonly platform: NodeJS.Platform
  readonly bindHost: string
}

const proxySessionRouteFor = ({ request, url }: RouteContext): RouteHandler | undefined => {
  if (isMethodRoute(request, url, "POST", "/v1/browser/proxy-session")) return writeProxySession
  return undefined
}

const eventCursorRouteFor = ({ request, url }: RouteContext): RouteHandler | undefined => {
  if (isMethodRoute(request, url, "GET", "/v1/events/cursor")) return writeEventCursor
  return undefined
}

const serverInfoRouteFor = ({ request, url }: RouteContext): RouteHandler | undefined => {
  if (isMethodRoute(request, url, "GET", "/v1/info")) return writeInfo
  if (isMethodRoute(request, url, "GET", "/v1/openapi.json")) return writeOpenApi
  return undefined
}

const connectionRouteFor = ({ request, url }: RouteContext): RouteHandler | undefined => {
  if (isMethodRoute(request, url, "GET", "/v1/capabilities")) return writeCapabilities
  if (isMethodRoute(request, url, "GET", "/v1/auth/connection-token")) return writeConnectionToken
  if (isMethodRoute(request, url, "POST", "/v1/auth/connection-token/rotate"))
    return rotateConnectionToken
  if (isMethodRoute(request, url, "POST", "/v1/auth/pairing-token")) return issuePairingToken
  return undefined
}

const writeNavigation = ({ services, response }: RouteContext): Promise<void> =>
  respondAfter(response, run(services.db.getNavigationSnapshot), (navigation) =>
    writeJson(response, 200, navigation)
  )

const streamEvents = ({ services, fanout, response, url }: RouteContext): Promise<void> =>
  respondAfter(response, handleEvents(services.db, fanout, url, response))

const writeProxySession = ({ routeState, request, response }: RouteContext): void => {
  if (request.headers.origin !== undefined) throw new HttpFailure(403, "Native clients only")
  if (routeState.browserProxy === undefined) throw new HttpFailure(501, "Browser proxy unavailable")

  response.setHeader("Cache-Control", "no-store")
  writeJson(response, 201, routeState.browserProxy.session)
}

const writeEventCursor = ({ services, response }: RouteContext): Promise<void> =>
  respondAfter(response, run(services.db.latestEventCursor), (cursor) =>
    writeJson(response, 200, { cursor })
  )

const writeInfo = (route: RouteContext): Promise<void> => {
  const head = infoHead(route)
  return respondAfter(route.response, simulatorsAvailable(route.config), (simulators) =>
    writeInfoWithMachine(route, head, simulators)
  )
}

const infoHead = ({ services, config }: RouteContext): InfoHead => ({
  cloudDeviceId: liveCloudDeviceId(config),
  identity: serverIdentity(config),
  features: configuredFeatures(services, config)
})

const serverIdentity = (config: CodevisorServerConfig): ServerIdentity => ({
  id: config.id,
  name: config.name,
  kind: config.kind,
  version: config.version,
  platform: process.platform,
  bindHost: config.host
})

const configuredFeatures = (
  services: CodevisorServerServices,
  config: CodevisorServerConfig
): ReadonlyArray<string> => [
  "browser-proxy-v1",
  "browser-http-proxy-v1",
  "browser-state-v1",
  ...(config.screenSharing === undefined ? [] : ["screen-sharing-v1", "computer-use-stream-v1"]),
  ...(services.mcp === undefined ? [] : ["live-preview-v1", "browser-host-v1"]),
  "canonical-chat-v1",
  ...(config.workspaceGit === true ? ["workspace-git-v1"] : []),
  "session-event-stream-v1",
  "transcript-pagination-v1",
  "bots-v1",
  "bot-projects-v1",
  "project-machine-setup-v1",
  ...(services.plugins === undefined ? [] : ["plugins-v1"])
]

const writeInfoWithMachine = (
  { services, config, response }: RouteContext,
  head: InfoHead,
  simulators: boolean
): Promise<void> => {
  const features = [...head.features, ...(simulators ? ["simulator-v1"] : [])]
  return respondAfter(response, run(services.db.getOrCreateInstanceId), (machineId) =>
    writeJson(response, 200, {
      ...head.identity,
      features,
      machineId,
      ...machineDetails(config, head.cloudDeviceId)
    })
  )
}

const machineDetails = (
  config: CodevisorServerConfig,
  cloudDeviceId: string | undefined
): MachineDetails => ({
  arch: process.arch,
  hostname: hostname(),
  maxUploadBytes: MAX_UPLOAD_BYTES,
  ...(config.icon === undefined ? {} : { icon: config.icon }),
  ...(cloudDeviceId === undefined ? {} : { cloudDeviceId })
})

const writeOpenApi = ({ config, response }: RouteContext): void =>
  writeJson(response, 200, makeOpenApiDocument(config.version))

const writeCapabilities = ({ services, response, url }: RouteContext): Promise<void> =>
  respondAfter(response, discoverCapabilities(services, url), (capabilities) =>
    writeJson(response, 200, capabilities)
  )

const writeConnectionToken = ({ services, response }: RouteContext): Promise<void> =>
  writeToken(response, 200, run(services.db.getOrCreateConnectionToken))

const rotateConnectionToken = ({ services, response }: RouteContext): Promise<void> =>
  writeToken(response, 201, run(services.db.rotateConnectionToken))

const issuePairingToken = ({ services, response }: RouteContext): Promise<void> =>
  writeToken(response, 201, run(services.db.issuePairingToken))

const writeToken = (
  response: ServerResponse,
  status: number,
  pending: Promise<string>
): Promise<void> =>
  respondAfter(response, pending, (token) =>
    writeJson(response, status, { token, createdAt: new Date().toISOString() })
  )

import { UpdateRunRequest, type UpdateInfo } from "@codevisor/api"
import type { ServerUpdateChannel } from "@codevisor/updater"

import { matchRoute, readSchema, run, swallowError, writeJson } from "../server-context.js"
import { publishUpdateChanged, withRestartDrain } from "../update-info-publish.js"
import { isMethodRoute, respondAfter } from "./route-context.js"
import type { RouteContext, RouteHandler } from "./route-context.js"

export const updateRouteFor = (route: RouteContext): RouteHandler | undefined => {
  const { request, url } = route
  if (isMethodRoute(request, url, "GET", "/v1/update")) return checkForUpdate
  if (isMethodRoute(request, url, "POST", "/v1/update/apply")) return applyUpdate
  return updateRunRouteFor(route) ?? harnessUpdateRouteFor(route)
}

export const restartRouteFor = (route: RouteContext): RouteHandler | undefined => {
  const drainRoute = restartDrainRouteFor(route)
  if (drainRoute !== undefined) return drainRoute

  if (isMethodRoute(route.request, route.url, "POST", "/v1/shutdown")) return requestShutdown
  return undefined
}

const updateRunRouteFor = ({ request, url }: RouteContext): RouteHandler | undefined => {
  if (url.pathname !== "/v1/updates/run") return undefined
  if (request.method === "GET") return writeUpdateRun
  if (request.method === "POST") return startUpdateRun
  if (request.method === "DELETE") return cancelUpdateRun
  return undefined
}

const harnessUpdateRouteFor = ({ request, url }: RouteContext): RouteHandler | undefined => {
  if (request.method !== "POST") return undefined
  const harnessId = matchRoute(url.pathname, "/v1/harnesses/:id/update")
  if (harnessId === undefined) return undefined
  return (route) => updateHarness(route, harnessId)
}

const restartDrainRouteFor = ({ request, url }: RouteContext): RouteHandler | undefined => {
  if (url.pathname !== "/v1/restart/drain") return undefined
  if (request.method === "GET") return writeRestartDrain
  if (request.method === "POST") return beginRestartDrain
  if (request.method === "DELETE") return cancelRestartDrain
  return undefined
}

const checkForUpdate = (route: RouteContext): Promise<void> => {
  const { config, response, url } = route
  if (config.updater === undefined) return writeStoredUpdateInfo(route)

  const force = url.searchParams.get("refresh") === "1"
  const channel = serverUpdateChannelFrom(url.searchParams.get("channel"))
  return respondAfter(response, config.updater.check({ channel, force }), (info) =>
    writeCheckedUpdate(route, info)
  )
}

const writeStoredUpdateInfo = ({ services, response }: RouteContext): Promise<void> =>
  respondAfter(response, run(services.db.getUpdateInfo), (info) => writeJson(response, 200, info))

const writeCheckedUpdate = (
  { services, fanout, routeState, response }: RouteContext,
  checked: UpdateInfo
): void => {
  const info = withRestartDrain(services, routeState, checked)
  publishUpdateChanged(services, fanout, routeState, info)
  writeJson(response, 200, info)
}

const applyUpdate = ({ routeState, response, url }: RouteContext): Promise<void> => {
  const channel = serverUpdateChannelFrom(url.searchParams.get("channel"))
  return respondAfter(response, routeState.updateRun.startServerUpdate(channel), (server) =>
    writeJson(response, server.accepted ? 202 : 200, server)
  )
}

const writeUpdateRun = ({ routeState, response }: RouteContext): void =>
  writeJson(response, 200, routeState.updateRun.state())

const startUpdateRun = async ({ routeState, request, response }: RouteContext): Promise<void> => {
  const started = routeState.updateRun.start(await readSchema(request, UpdateRunRequest))
  return respondAfter(response, started, (progress) => writeJson(response, 202, progress))
}

const cancelUpdateRun = ({ routeState, response }: RouteContext): Promise<void> =>
  respondAfter(response, routeState.updateRun.cancel(), (progress) =>
    writeJson(response, 200, progress)
  )

const updateHarness = ({ routeState, response }: RouteContext, harnessId: string): Promise<void> =>
  respondAfter(response, routeState.updateRun.start({ harnessIds: [harnessId] }), (started) =>
    writeJson(response, 202, {
      accepted: true,
      queued: false,
      lifecycle: { phase: "updating", startedAt: started.run.startedAt }
    })
  )

const writeRestartDrain = ({ routeState, response }: RouteContext): void =>
  writeJson(response, 200, routeState.restart.state())

const beginRestartDrain = ({ routeState, response }: RouteContext): void => {
  void routeState.restart.begin().catch(swallowError)
  writeJson(response, 202, routeState.restart.state())
}

const cancelRestartDrain = ({ routeState, response }: RouteContext): Promise<void> =>
  respondAfter(response, routeState.restart.cancel(), (drain) => writeJson(response, 200, drain))

const requestShutdown = ({ config, response }: RouteContext): void => {
  writeJson(response, 202, { ok: true })
  config.onShutdownRequested?.()
}

const serverUpdateChannelFrom = (value: string | null): ServerUpdateChannel =>
  value === "alpha" ? "alpha" : "stable"

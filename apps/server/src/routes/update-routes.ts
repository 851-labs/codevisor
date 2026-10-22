import type { ServerResponse } from "node:http"

import type { RestartDrainState, UpdateApplyState, UpdateInfo } from "@codevisor/api"
import type { ServerUpdateChannel } from "@codevisor/updater"

import { applyAfterDrain } from "../apply-after-drain.js"
import {
  appendAndPublish,
  failureMessage,
  HttpFailure,
  run,
  swallowError,
  writeJson
} from "../server-context.js"
import type {
  CodevisorServerConfig,
  CodevisorServerServices,
  CodevisorServerUpdater,
  EventFanout,
  RouteState
} from "../server-context.js"
import { isMethodRoute, respondAfter } from "./route-context.js"
import type { RouteContext, RouteHandler } from "./route-context.js"

export const updateRouteFor = ({ request, url }: RouteContext): RouteHandler | undefined => {
  if (isMethodRoute(request, url, "GET", "/v1/update")) return checkForUpdate
  if (isMethodRoute(request, url, "POST", "/v1/update/apply")) return applyUpdate
  return undefined
}

export const restartRouteFor = (route: RouteContext): RouteHandler | undefined => {
  const drainRoute = restartDrainRouteFor(route)
  if (drainRoute !== undefined) return drainRoute

  if (isMethodRoute(route.request, route.url, "POST", "/v1/shutdown")) return requestShutdown
  return undefined
}

type UpdatableConfig = CodevisorServerConfig & { readonly updater: CodevisorServerUpdater }

interface AcceptedUpdate {
  readonly accepted: true
  readonly targetVersion: string
  readonly targetBuildNumber?: number
  readonly draining: boolean
}

interface UpdateRequest {
  readonly busy: boolean
  readonly channel: ServerUpdateChannel
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
  if (!canUpdate(config)) return writeStoredUpdateInfo(route)

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
  const info = withRestartDrain(routeState, checked)
  publishUpdateChanged(services, fanout, routeState, info)
  writeJson(response, 200, info)
}

const applyUpdate = (route: RouteContext): Promise<void> => {
  const { config, routeState, response, url } = route
  if (!canUpdate(config)) throw new HttpFailure(409, "This server does not support remote updates")

  const update: UpdateRequest = {
    busy: hasActiveChats(routeState),
    channel: serverUpdateChannelFrom(url.searchParams.get("channel"))
  }
  return respondAfter(
    response,
    config.updater.check({ channel: update.channel, force: true }),
    (info) => startUpdate(route, config, update, info)
  )
}

const startUpdate = (
  route: RouteContext,
  config: UpdatableConfig,
  update: UpdateRequest,
  info: UpdateInfo
): void => {
  const { services, fanout, routeState, response } = route
  publishUpdateChanged(services, fanout, routeState, info)
  if (!info.updateAvailable) return writeUpToDate(response, info)

  writeJson(response, 202, acceptedUpdate(info, update.busy))
  applyWhenDrained(route, config.updater, update.channel, info)
}

const writeUpToDate = (response: ServerResponse, info: UpdateInfo): void =>
  writeJson(response, 200, { accepted: false, targetVersion: info.currentVersion })

const acceptedUpdate = (info: UpdateInfo, busy: boolean): AcceptedUpdate => ({
  accepted: true,
  targetVersion: info.latestVersion,
  ...(info.latestBuildNumber === undefined ? {} : { targetBuildNumber: info.latestBuildNumber }),
  draining: busy
})

const applyWhenDrained = (
  { services, fanout, routeState }: RouteContext,
  updater: CodevisorServerUpdater,
  channel: ServerUpdateChannel,
  info: UpdateInfo
): void => {
  void applyAfterDrain(
    routeState.restart,
    () => publishUpdateChanged(services, fanout, routeState, withRestartDrain(routeState, info)),
    () => updater.apply({ channel })
  ).catch(
    /* v8 ignore next */
    (cause: unknown) => console.log(`Update apply failed: ${failureMessage(cause)}`)
  )
}

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

const canUpdate = (config: CodevisorServerConfig): config is UpdatableConfig =>
  config.updater !== undefined

const hasActiveChats = (routeState: RouteState): boolean =>
  routeState.activePromptSessions.size > 0 || routeState.activeTurnSessions.size > 0

const serverUpdateChannelFrom = (value: string | null): ServerUpdateChannel =>
  value === "alpha" ? "alpha" : "stable"

const updateInfoSignature = (info: UpdateInfo): string =>
  JSON.stringify([
    info.updateAvailable,
    info.latestVersion,
    info.latestBuildNumber ?? null,
    info.currentVersion,
    info.channel,
    info.lastApply?.state ?? null,
    info.lastApply?.message ?? null,
    info.lastApply?.progress ?? null,
    info.lastApply?.at ?? null
  ])

const withRestartDrain = (routeState: RouteState, info: UpdateInfo): UpdateInfo => {
  const drain = routeState.restart.state()
  if (drainLeavesUpdate(drain, info)) return info
  if (installedAfterDrain(drain, info)) return info

  const chats = `${drain.remaining} chat${drain.remaining === 1 ? "" : "s"}`
  return { ...info, lastApply: drainingApply(drain, info, chats) }
}

const drainLeavesUpdate = (drain: RestartDrainState, info: UpdateInfo): boolean =>
  drain.state === "idle" || info.lastApply?.state === "failed"

const installedAfterDrain = (drain: RestartDrainState, info: UpdateInfo): boolean =>
  drain.state === "drained" &&
  info.lastApply?.state === "installing" &&
  Date.parse(info.lastApply.at) >= Date.parse(drain.startedAt)

const drainingApply = (
  drain: RestartDrainState,
  info: UpdateInfo,
  chats: string
): UpdateApplyState => ({
  state: drain.state === "draining" ? "draining" : "installing",
  message:
    drain.state === "draining"
      ? `Pausing ${chats} for the update`
      : "Restarting to install the update",
  targetVersion: info.latestVersion,
  at: drain.startedAt
})

const publishUpdateChanged = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  info: UpdateInfo
): void => {
  const signature = updateInfoSignature(info)
  if (routeState.updateSignature.value === signature) return
  routeState.updateSignature.value = signature
  void appendAndPublish(services.db, fanout, "update.changed", "server", info).catch(swallowError)
}

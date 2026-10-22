import type { UpdateApplyState, UpdateInfo } from "@codevisor/api"

import {
  appendAndPublish,
  swallowError,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "./server-context.js"

export const withRestartDrain = (
  services: CodevisorServerServices,
  routeState: RouteState,
  info: UpdateInfo
): UpdateInfo => {
  const drain = routeState.restart.state()
  if (drain.state === "idle" || drain.harnessIds !== undefined) return info
  if (info.lastApply?.state === "failed") return info
  if (installStartedAfterDrain(info, drain.startedAt)) return info

  return { ...info, lastApply: restartProgress(services, routeState, info, drain) }
}

export const publishUpdateChanged = (
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

const installStartedAfterDrain = (info: UpdateInfo, drainStartedAt: string): boolean =>
  info.lastApply?.state === "installing" &&
  Date.parse(info.lastApply.at) >= Date.parse(drainStartedAt)

const restartProgress = (
  services: CodevisorServerServices,
  routeState: RouteState,
  info: UpdateInfo,
  drain: ReturnType<RouteState["restart"]["state"]>
): UpdateApplyState => {
  const updating = routeState.updateRun.state().currentHarnessId
  return {
    state: drain.state === "draining" || updating !== undefined ? "draining" : "installing",
    message: restartMessage(services, drain, updating),
    targetVersion: info.latestVersion,
    at: drain.startedAt
  }
}

const restartMessage = (
  services: CodevisorServerServices,
  drain: ReturnType<RouteState["restart"]["state"]>,
  updatingHarnessId: string | undefined
): string => {
  if (updatingHarnessId !== undefined) {
    return `Updating ${harnessName(services, updatingHarnessId)} first`
  }
  if (drain.state === "draining") {
    return `Pausing ${drain.remaining} chat${drain.remaining === 1 ? "" : "s"} for the update`
  }
  return "Restarting to install the update"
}

const harnessName = (services: CodevisorServerServices, harnessId: string): string =>
  services.agents.catalog.find((definition) => definition.id === harnessId)?.name ?? harnessId

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

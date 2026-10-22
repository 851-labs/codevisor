import type { UpdateInfo } from "@codevisor/api"

import type { PausedTurnStore } from "./paused-turns.js"
import type { RestartCoordinator } from "./restart-drain.js"
import {
  appendAndPublish,
  swallowError,
  type CodevisorServerServices,
  type CodevisorServerUpdater,
  type EventFanout,
  type RouteState
} from "./server-context.js"
import { publishUpdateChanged, withRestartDrain } from "./update-info-publish.js"
import { makeUpdateRun, type ServerUpdateSteps, type UpdateRun } from "./update-run.js"

export interface ServerUpdateRunDeps {
  readonly services: CodevisorServerServices
  readonly fanout: EventFanout
  readonly restart: RestartCoordinator
  readonly pausedTurns: PausedTurnStore
  readonly updater: CodevisorServerUpdater | undefined
  readonly routeState: () => RouteState
}

export const makeServerUpdateRun = (deps: ServerUpdateRunDeps): UpdateRun => {
  const { services, fanout, routeState } = deps
  const announce = (info: UpdateInfo): void => {
    publishUpdateChanged(
      services,
      fanout,
      routeState(),
      withRestartDrain(services, routeState(), info)
    )
  }
  const updateRun = makeUpdateRun({
    restart: deps.restart,
    harnesses: services.lifecycle,
    server: serverUpdateSteps(deps.updater, announce),
    pausedSessionIds: () => deps.pausedTurns.read().map((turn) => turn.sessionId),
    onChange: () => {
      void appendAndPublish(
        services.db,
        fanout,
        "update.run.updated",
        "server",
        updateRun.state()
      ).catch(swallowError)
    }
  })
  return updateRun
}

const serverUpdateSteps = (
  updater: CodevisorServerUpdater | undefined,
  announce: (info: UpdateInfo) => void
): ServerUpdateSteps | undefined => {
  if (updater === undefined) return undefined

  return {
    check: async (channel) => {
      const info = await updater.check({ channel, force: true })
      announce(info)
      return info
    },
    apply: async (channel, info) => {
      announce(info)
      await updater.apply({ channel })
    }
  }
}

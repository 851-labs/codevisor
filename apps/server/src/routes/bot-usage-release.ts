import type { EventEnvelope } from "@codevisor/api"

import {
  run,
  swallowError,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { isRecord } from "../unknown-values.js"
import { conversationalBotForSession } from "./bot-turns.js"
import { drainPromptQueue } from "./prompt-queue.js"

export const makeUsageHoldReleaseListener =
  (
    services: CodevisorServerServices,
    fanout: EventFanout,
    routeState: RouteState,
    serverId: string
  ) =>
  (event: EventEnvelope): void => {
    if (!autoResumeCleared(event)) return

    void releaseHeldWakeUps(services, fanout, routeState, serverId, event.subjectId).catch(
      swallowError
    )
  }

const autoResumeCleared = (event: EventEnvelope): boolean =>
  event.kind === "session.autoResume.updated" &&
  isRecord(event.payload) &&
  event.payload.state === "cleared"

const releaseHeldWakeUps = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string,
  sessionId: string
): Promise<void> => {
  if ((await run(services.db.getAutoResume(sessionId))) !== undefined) return
  if ((await conversationalBotForSession(services, sessionId)) === undefined) return

  await drainPromptQueue(services, fanout, routeState, serverId, sessionId)
}

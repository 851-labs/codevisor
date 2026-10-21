import type { PromptDelivered, PromptDelivery } from "@codevisor/api"

import {
  HttpFailure,
  run,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { conversationalBotForSession } from "./bot-turns.js"
import { hasLiveTurn, steerQueuedPrompt } from "./prompt-queue.js"

export const defaultPromptDelivery: PromptDelivery = "steer"

export const UPDATING_MESSAGE = "Codevisor is updating. Send this again once the update finishes."

export const refuseWhileUpdating = (routeState: RouteState, sessionId: string): void => {
  if (routeState.restart.isGated() || routeState.updateResume.isPending(sessionId)) {
    throw new HttpFailure(409, UPDATING_MESSAGE, "updating")
  }
}

export interface PromptDeliveryOutcome {
  readonly delivered: PromptDelivered
  readonly steerDeclined?: true
}

const steerDeclined: PromptDeliveryOutcome = { delivered: "queued", steerDeclined: true }

export const deliverQueuedPrompt = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string,
  sessionId: string,
  queueItemId: string,
  delivery: PromptDelivery
): Promise<PromptDeliveryOutcome> => {
  if (!hasLiveTurn(routeState, sessionId)) {
    return idleOutcome(services, routeState, sessionId, queueItemId)
  }
  if (!(await steersRunningTurn(services, sessionId, delivery))) return { delivered: "queued" }
  if (await promptsAreHeld(services, routeState, sessionId)) return steerDeclined

  if (await steerQueuedPrompt(services, fanout, serverId, sessionId, queueItemId)) {
    return { delivered: "steered" }
  }
  if (!hasLiveTurn(routeState, sessionId)) {
    return idleOutcome(services, routeState, sessionId, queueItemId)
  }
  return steerDeclined
}

export const sendQueuedPromptNow = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string,
  sessionId: string,
  queueItemId: string
): Promise<PromptDeliveryOutcome> => {
  await moveToFrontOfQueue(services, sessionId, queueItemId)
  return deliverQueuedPrompt(
    services,
    fanout,
    routeState,
    serverId,
    sessionId,
    queueItemId,
    "steer"
  )
}

const steersRunningTurn = async (
  services: CodevisorServerServices,
  sessionId: string,
  delivery: PromptDelivery
): Promise<boolean> =>
  delivery === "steer" || (await conversationalBotForSession(services, sessionId)) !== undefined

const idleOutcome = async (
  services: CodevisorServerServices,
  routeState: RouteState,
  sessionId: string,
  queueItemId: string
): Promise<PromptDeliveryOutcome> => {
  if (await startsRightAway(services, routeState, sessionId, queueItemId)) {
    return { delivered: "sent" }
  }
  return { delivered: "queued" }
}

const startsRightAway = async (
  services: CodevisorServerServices,
  routeState: RouteState,
  sessionId: string,
  queueItemId: string
): Promise<boolean> => {
  if (await promptsAreHeld(services, routeState, sessionId)) return false

  const [next] = await run(services.db.listPromptQueue(sessionId))
  return next?.id === queueItemId
}

const promptsAreHeld = async (
  services: CodevisorServerServices,
  routeState: RouteState,
  sessionId: string
): Promise<boolean> => {
  if (routeState.restart.isGated()) return true

  const { harnessId } = await run(services.db.getSessionSummary(sessionId))
  return services.lifecycle?.isGated(harnessId) === true
}

const moveToFrontOfQueue = async (
  services: CodevisorServerServices,
  sessionId: string,
  queueItemId: string
): Promise<void> => {
  const queue = await run(services.db.listPromptQueue(sessionId))
  if (!queue.some((item) => item.id === queueItemId)) {
    throw new HttpFailure(404, `Queued prompt not found: ${queueItemId}`)
  }
  await run(services.db.reorderPromptQueue(sessionId, [queueItemId]))
}

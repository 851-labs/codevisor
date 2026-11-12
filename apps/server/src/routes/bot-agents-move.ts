import {
  FLEET_AGENTS_MOVED_PATH,
  type SessionSubscription,
  type SessionSummary
} from "@codevisor/api"
import type { CreatedAgentsMove } from "@codevisor/db"

import { broadcastToOtherMachines } from "../fleet-broadcast.js"
import {
  appendAndPublish,
  run,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"

export interface AgentsMove {
  readonly fromAgentId: string
  readonly toAgentId: string
}

export const moveBotAgents = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  move: AgentsMove
): Promise<ReadonlyArray<SessionSummary>> => {
  const moved = await moveLocalAgents(services, fanout, { ...move, creatorMachineId: serverId })
  await moveSubscriptions(services, move, moved)
  await broadcastToOtherMachines(services, serverId, {
    kind: "agents_moved",
    path: FLEET_AGENTS_MOVED_PATH,
    args: { fromAgentId: move.fromAgentId, toAgentId: move.toAgentId }
  })
  return moved
}

export const moveLocalAgents = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  move: CreatedAgentsMove
): Promise<ReadonlyArray<SessionSummary>> => {
  const moved: Array<SessionSummary> = []
  for (const id of await run(services.db.moveCreatedAgents(move))) {
    const session = await run(services.db.getSessionSummary(id))
    await appendAndPublish(services.db, fanout, "session.updated", session.id, session)
    moved.push(session)
  }
  return moved
}

const moveSubscriptions = async (
  services: CodevisorServerServices,
  move: AgentsMove,
  moved: ReadonlyArray<SessionSummary>
): Promise<void> => {
  const movedIds = new Set(moved.map((session) => session.id.toLowerCase()))
  const subscriptions = await run(services.db.listSessionSubscriptions(move.fromAgentId))
  for (const subscription of subscriptions) {
    if (!movedIds.has(subscription.targetSessionId.toLowerCase())) continue
    await resubscribe(services, subscription, move.toAgentId)
  }
}

const resubscribe = async (
  services: CodevisorServerServices,
  subscription: SessionSubscription,
  subscriberSessionId: string
): Promise<void> => {
  await run(services.db.deleteSessionSubscription(subscription.id))
  await run(
    services.db.createSessionSubscription({
      subscriberSessionId,
      targetSessionId: subscription.targetSessionId,
      events: subscription.events,
      once: subscription.once
    })
  )
}

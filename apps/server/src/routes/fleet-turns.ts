import { FLEET_SESSION_EVENT_PATH, type SessionSummary } from "@codevisor/api"
import type { FleetMessage, FleetPendingTurn } from "@codevisor/db"

import type { FleetLink } from "../infra/fleet-outbox.js"
import { run, type CodevisorServerServices } from "../server-context.js"
import { fleetBotWake, type FleetBotWake, type FleetSessionEvent } from "./fleet-session-events.js"
import { fromMachine, turnEndedMessage } from "./session-event-messages.js"
import { finalAssistantText } from "./session-event-router.js"

export interface FleetSender {
  readonly serverId: string
  readonly fleet: FleetLink
}

export const fleetTurnSender = (
  services: CodevisorServerServices,
  serverId: string,
  fleet: FleetLink | undefined
): (() => Promise<void>) => {
  if (fleet === undefined) return async () => undefined
  return () => sendFinishedFleetTurns(services, { serverId, fleet })
}

export const sendFinishedFleetTurns = async (
  services: CodevisorServerServices,
  sender: FleetSender
): Promise<void> => {
  for (const turn of await run(services.db.listFleetPendingTurns)) {
    const message = await turnMessage(services, sender, turn)
    await run(services.db.promoteFleetTurn(turn, message))
  }
  await sender.fleet.outbox.flush()
}

const turnMessage = async (
  services: CodevisorServerServices,
  sender: FleetSender,
  turn: FleetPendingTurn
): Promise<FleetMessage | undefined> => {
  const child = await run(services.db.getSessionSummary(turn.sessionId)).catch(() => undefined)
  if (child === undefined) return undefined
  const wake = await fleetBotWake(services, child)
  if (wake === undefined) return undefined

  const self = { id: sender.serverId, name: await machineName(sender) }
  const text = await eventText(services, self, child, turn)
  return fleetMessage(self, { child, wake, turn, text })
}

interface SelfMachine {
  readonly id: string
  readonly name: string
}

interface FinishedTurn {
  readonly child: SessionSummary
  readonly wake: FleetBotWake
  readonly turn: FleetPendingTurn
  readonly text: string
}

const eventText = async (
  services: CodevisorServerServices,
  self: SelfMachine,
  child: SessionSummary,
  turn: FleetPendingTurn
): Promise<string> => {
  const final = await finalAssistantText(services, child.id)
  return fromMachine(turnEndedMessage(child, turn.stopReason, final.text), self).text
}

const fleetMessage = (self: SelfMachine, finished: FinishedTurn): FleetMessage => {
  const { child, wake, turn, text } = finished
  const id = `${self.id}:turn_ended:${child.id}:${turn.revision}`
  const event: FleetSessionEvent = {
    sessionId: wake.subscriber.sessionId,
    botId: wake.bot.botId,
    deliveryId: id,
    text
  }
  return {
    id,
    machineId: wake.subscriber.machineId,
    path: FLEET_SESSION_EVENT_PATH,
    args: { ...event },
    origin: {
      machineId: self.id,
      machineName: self.name,
      sessionId: child.id,
      sessionTitle: child.title
    },
    createdAt: new Date().toISOString()
  }
}

const machineName = async (sender: FleetSender): Promise<string> =>
  (await sender.fleet.machines.list()).find((machine) => machine.isCurrent)?.name ?? sender.serverId

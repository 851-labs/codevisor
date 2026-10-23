import { parseRemoteSessionKey, type RemoteSessionRef, type SessionSummary } from "@codevisor/api"
import type { BotLink } from "@codevisor/db"

import {
  HttpFailure,
  run,
  sessionIsArchived,
  type CodevisorServerServices,
  type RouteState
} from "../server-context.js"
import { stringField } from "../unknown-values.js"
import { conversationalBotForSession } from "./bot-turns.js"
import type { FleetCall } from "./fleet-calls.js"

export interface FleetSessionEvent {
  readonly sessionId: string
  readonly botId: string
  readonly deliveryId: string
  readonly text: string
}

export interface FleetBotWake {
  readonly subscriber: RemoteSessionRef
  readonly bot: Required<BotLink>
}

export const fleetBotWake = async (
  services: CodevisorServerServices,
  child: Pick<SessionSummary, "id" | "parentSessionId">
): Promise<FleetBotWake | undefined> => {
  const link = await run(services.db.findFleetBotLink(child.id))
  if (link === undefined || link.parentSessionId !== child.parentSessionId) return undefined
  const subscriber = parseRemoteSessionKey(link.parentSessionId)
  if (subscriber?.machineId !== link.bot.botMachineId) return undefined
  return { subscriber, bot: link.bot }
}

export const receiveSessionEvent = async (
  services: CodevisorServerServices,
  routeState: RouteState,
  call: FleetCall,
  args: unknown
): Promise<boolean> => {
  if (!call.verified) throw new HttpFailure(403, "Only machines on this account can send events")
  const event = parseFleetSessionEvent(args)
  if (event === undefined)
    throw new HttpFailure(400, "Expected { sessionId, botId, deliveryId, text }")
  const target = await run(services.db.getSessionSummary(event.sessionId)).catch(() => undefined)
  if (target === undefined) throw new HttpFailure(404, "No such session on this machine")
  if (!(await isBotHome(services, event))) {
    throw new HttpFailure(403, "Events only go to the bot that started the chat")
  }
  if (await sessionIsArchived(services, target)) throw new HttpFailure(409, "That bot is archived")

  const accepted = await run(
    services.db.acceptFleetPrompt({
      deliveryId: event.deliveryId,
      receivedAt: new Date().toISOString(),
      sessionId: target.id,
      text: event.text
    })
  )
  if (accepted) void routeState.drainSessionQueue?.(target.id)
  return accepted
}

const isBotHome = async (
  services: CodevisorServerServices,
  event: FleetSessionEvent
): Promise<boolean> => {
  const bot = await conversationalBotForSession(services, event.sessionId)
  return bot?.id.toLowerCase() === event.botId.toLowerCase()
}

const parseFleetSessionEvent = (value: unknown): FleetSessionEvent | undefined => {
  const sessionId = stringField(value, "sessionId")
  const botId = stringField(value, "botId")
  const deliveryId = stringField(value, "deliveryId")
  const text = stringField(value, "text")
  if (sessionId === undefined || botId === undefined) return undefined
  if (deliveryId === undefined || text === undefined) return undefined
  return { sessionId, botId, deliveryId, text }
}

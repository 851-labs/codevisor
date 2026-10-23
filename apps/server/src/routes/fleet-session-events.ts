import {
  FLEET_SESSION_EVENT_PATH,
  parseRemoteSessionKey,
  remoteSessionKey,
  type RemoteSessionRef,
  type SessionSummary
} from "@codevisor/api"
import type { BotLink } from "@codevisor/db"

import type { MachineLink } from "../infra/machine-link.js"
import {
  HttpFailure,
  run,
  type CodevisorServerServices,
  type RouteState
} from "../server-context.js"
import { stringField } from "../unknown-values.js"
import { conversationalBotForSession } from "./bot-turns.js"
import type { FleetCall } from "./fleet-calls.js"
import { fromMachine, type SessionEventMessage } from "./session-event-messages.js"

export interface FleetSessionEvent {
  readonly sessionId: string
  readonly botId: string
  readonly key: string
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

export const forwardSessionEvent = async (
  machines: MachineLink | undefined,
  serverId: string,
  source: Pick<SessionSummary, "id" | "title">,
  wake: FleetBotWake,
  message: SessionEventMessage
): Promise<void> => {
  if (machines === undefined) return

  const self = { id: serverId, name: await currentMachineName(machines, serverId) }
  const attributed = fromMachine(message, self)
  const event: FleetSessionEvent = {
    sessionId: wake.subscriber.sessionId,
    botId: wake.bot.botId,
    key: attributed.key,
    text: attributed.text
  }
  await machines.invoke(wake.subscriber.machineId, FLEET_SESSION_EVENT_PATH, event, {
    machineId: self.id,
    machineName: self.name,
    sessionId: source.id,
    sessionTitle: source.title
  })
}

export const receiveSessionEvent = async (
  services: CodevisorServerServices,
  routeState: RouteState,
  call: FleetCall,
  args: unknown
): Promise<void> => {
  if (!call.verified) throw new HttpFailure(403, "Only machines on this account can send events")
  const event = parseFleetSessionEvent(args)
  if (event === undefined) throw new HttpFailure(400, "Expected { sessionId, botId, key, text }")
  const target = await run(services.db.getSessionSummary(event.sessionId)).catch(() => undefined)
  if (target === undefined) throw new HttpFailure(404, "No such session on this machine")
  if (!(await isBotHome(services, event))) {
    throw new HttpFailure(403, "Events only go to the bot that started the chat")
  }

  await routeState.deliverSessionEvent?.(event.sessionId, {
    message: { key: event.key, text: event.text },
    sourceSessionId: remoteSessionKey(call.origin.machineId, call.origin.sessionId)
  })
}

const isBotHome = async (
  services: CodevisorServerServices,
  event: FleetSessionEvent
): Promise<boolean> => {
  const bot = await conversationalBotForSession(services, event.sessionId)
  return bot?.id.toLowerCase() === event.botId.toLowerCase()
}

const currentMachineName = async (machines: MachineLink, serverId: string): Promise<string> =>
  (await machines.list()).find((machine) => machine.isCurrent)?.name ?? serverId

const parseFleetSessionEvent = (value: unknown): FleetSessionEvent | undefined => {
  const sessionId = stringField(value, "sessionId")
  const botId = stringField(value, "botId")
  const key = stringField(value, "key")
  const text = stringField(value, "text")
  if (sessionId === undefined || botId === undefined) return undefined
  if (key === undefined || text === undefined) return undefined
  return { sessionId, botId, key, text }
}

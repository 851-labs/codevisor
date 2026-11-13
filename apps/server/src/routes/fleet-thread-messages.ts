import { decode, FleetThreadMessage, type Bot, type ThreadParticipant } from "@codevisor/api"
import type { ThreadParty } from "@codevisor/db"

import { appendAndPublish, HttpFailure, run } from "../server-context.js"
import type { FleetCall } from "./fleet-calls.js"
import type { RouteContext } from "./route-context.js"
import { deliverToChat, sameParticipant, threadEvent } from "./thread-delivery.js"

const decodeFleetThreadMessage = decode(FleetThreadMessage)

export const receiveThreadMessage = async (
  route: RouteContext,
  call: FleetCall,
  args: unknown
): Promise<boolean> => {
  if (!call.verified) throw new HttpFailure(403, "Only machines on this account can send messages")
  const { services, fanout, config } = route
  const sent = parsed(args)
  const here = sent.participants.find((participant) => participant.machineId === config.id)
  const there = sent.participants.find(
    (participant) => participant.machineId === call.origin.machineId
  )
  const bot = await botHere(route, here)
  if (there?.botId === undefined || bot === undefined) {
    throw new HttpFailure(404, "That thread is not between a bot here and a bot there")
  }

  const local: ThreadParty = { kind: "bot", botId: bot.id }
  const remote: ThreadParty = {
    kind: "remoteBot",
    botId: there.botId,
    agentId: there.agentId,
    machineId: call.origin.machineId,
    name: there.name
  }
  const thread = await run(services.db.openThread(local, remote, sent.threadId))
  const from = sameParticipant(sent.message.from, there) ? remote : local
  const { id, text, createdAt } = sent.message
  const { message, created } = await run(
    services.db.appendThreadMessage(thread.threadId, from, { id, text, createdAt })
  )
  if (!created) return false

  await appendAndPublish(services.db, fanout, "thread.message", thread.threadId, { message })
  if (from === remote) await deliverToChat(route, bot.sessionId, threadEvent(route, message))
  return true
}

const parsed = (args: unknown): FleetThreadMessage => {
  try {
    return decodeFleetThreadMessage(args)
  } catch {
    throw new HttpFailure(400, "Expected { threadId, participants, message }")
  }
}

const botHere = async (
  { services }: RouteContext,
  participant: ThreadParticipant | undefined
): Promise<Bot | undefined> => {
  if (participant?.botId === undefined) return undefined
  return run(services.db.getBot(participant.botId))
}

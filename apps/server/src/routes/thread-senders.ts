import type { Bot, SessionSummary } from "@codevisor/api"
import type { ThreadParty } from "@codevisor/db"

import { HttpFailure, run } from "../server-context.js"
import { botForChat } from "./bot-turns.js"
import { assertAgentVerified, remoteCallerAgent } from "./fleet-calls.js"
import type { RouteContext } from "./route-context.js"

export interface SenderClaim {
  readonly agentId?: string | undefined
  readonly machineId?: string | undefined
  readonly botId?: string | undefined
  readonly name?: string | undefined
}

export interface Sender {
  readonly party: ThreadParty
  readonly chat?: SessionSummary
}

export const requireSender = async (route: RouteContext, claim: SenderClaim): Promise<Sender> => {
  const { agentId, machineId } = claim
  if (agentId === undefined) {
    throw new HttpFailure(
      422,
      "Only a bot or an agent can message a bot this way. The user writes to a bot in the app"
    )
  }
  if (machineId !== undefined && machineId !== route.config.id) {
    return senderElsewhere(route, { ...claim, agentId, machineId })
  }
  return senderHere(route, agentId)
}

export const refuseOwnBot = (sender: Sender, bot: Bot): void => {
  if (sender.party.kind === "bot" && sender.party.botId === bot.id) {
    throw new HttpFailure(409, "A bot can't message itself")
  }
  const { createdByAgentId, isDetached } = sender.chat ?? {}
  if (createdByAgentId?.toLowerCase() === bot.sessionId.toLowerCase() && isDetached !== true) {
    throw new HttpFailure(
      409,
      `${bot.name} started you and already gets your reply when your turn ends. Put what it needs in your final message`
    )
  }
}

const senderElsewhere = (
  { services, request, config }: RouteContext,
  claim: SenderClaim & { readonly agentId: string; readonly machineId: string }
): Sender => {
  const { agentId, machineId, botId, name } = claim
  assertAgentVerified(config.id, { agentId, machineId }, remoteCallerAgent(services, request))
  if (botId === undefined) return { party: { kind: "agent", agentId, machineId, name } }
  return { party: { kind: "remoteBot", botId, agentId, machineId, name: name ?? "Bot" } }
}

const senderHere = async ({ services, config }: RouteContext, agentId: string): Promise<Sender> => {
  const chat = await run(services.db.getSessionSummary(agentId)).catch(() => undefined)
  if (chat === undefined) throw new HttpFailure(404, `Agent not found: ${agentId}`)
  const bot = await botForChat(services, chat.id)
  const party: ThreadParty =
    bot === undefined
      ? { kind: "agent", agentId: chat.id, machineId: config.id }
      : { kind: "bot", botId: bot.id }
  return { party, chat }
}

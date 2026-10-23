import { parseRemoteSessionKey } from "@codevisor/api"
import type { BotLink, BotOwnerQuery } from "@codevisor/db"

import type { RemoteBotLink } from "../infra/fleet-tickets.js"
import { HttpFailure, run, type CodevisorServerServices } from "../server-context.js"

export const assertNotOwnedByBot = async (
  services: CodevisorServerServices,
  query: BotOwnerQuery,
  action: string
): Promise<void> => {
  const bot = await run(services.db.findBotOwning(query))
  if (bot !== undefined) {
    throw new HttpFailure(409, `Cannot ${action}: it belongs to the bot ${bot.name}`)
  }
}

export const botForParentSession = async (
  services: CodevisorServerServices,
  serverId: string,
  parentSessionId: string | undefined,
  verified?: RemoteBotLink
): Promise<Partial<BotLink>> => {
  if (parentSessionId === undefined) return {}
  if (parseRemoteSessionKey(parentSessionId) !== undefined) {
    return botFromFleet(services, serverId, parentSessionId, verified)
  }
  return (await run(services.db.findBotLinkForSession(parentSessionId))) ?? {}
}

const botFromFleet = async (
  services: CodevisorServerServices,
  serverId: string,
  parentSessionId: string,
  verified: RemoteBotLink | undefined
): Promise<Partial<BotLink>> => {
  if (verified?.parentSessionId !== parentSessionId) return {}
  if (verified.bot.botMachineId !== serverId) return verified.bot

  const local = await run(services.db.getBot(verified.bot.botId))
  return local === undefined ? {} : { botId: local.id }
}

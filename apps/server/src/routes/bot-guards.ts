import type { BotOwnerQuery } from "@codevisor/db"

import { HttpFailure, run, type CodevisorServerServices } from "../server-context.js"

export const refuseBotAsAgent = async (
  services: CodevisorServerServices,
  agentId: string,
  action: string
): Promise<void> => {
  const bot = await run(services.db.findBotOwning({ sessionId: agentId }))
  if (bot === undefined || bot.sessionId.toLowerCase() !== agentId.toLowerCase()) return

  throw new HttpFailure(
    409,
    `Cannot ${action} ${bot.name}: it is a bot, not an agent. Bots belong to the user`
  )
}

export const assertNotOwnedByBot = async (
  services: CodevisorServerServices,
  query: BotOwnerQuery,
  action: string,
  remedy?: string
): Promise<void> => {
  const bot = await run(services.db.findBotOwning(query))
  if (bot === undefined) return

  const refusal = `Cannot ${action}: it belongs to the bot ${bot.name}`
  throw new HttpFailure(409, remedy === undefined ? refusal : `${refusal}. ${remedy}`)
}

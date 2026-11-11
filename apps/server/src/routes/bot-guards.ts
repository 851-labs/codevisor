import type { BotOwnerQuery } from "@codevisor/db"

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

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

export const botForParentSession = async (
  services: CodevisorServerServices,
  parentSessionId: string | undefined
): Promise<{ readonly botId?: string }> => {
  if (parentSessionId === undefined) return {}
  const parent = await run(services.db.getSessionSummary(parentSessionId)).catch(() => undefined)
  const workspaceId = parent?.workspaceId
  if (workspaceId === undefined) return {}
  const home = await run(services.db.findBotOwning({ workspaceId }))
  if (home !== undefined) return { botId: home.id }
  const workspace = (await run(services.db.listWorkspaces)).find(
    (candidate) => candidate.id === workspaceId
  )
  return workspace?.botId === undefined ? {} : { botId: workspace.botId }
}

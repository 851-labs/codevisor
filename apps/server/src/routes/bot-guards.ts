import { parseRemoteSessionKey } from "@codevisor/api"
import type { BotLink, BotOwnerQuery, WorkspaceBotFields } from "@codevisor/db"

import type { VerifiedRemoteParent } from "../infra/fleet-tickets.js"
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
  verified?: VerifiedRemoteParent
): Promise<WorkspaceBotFields> => {
  if (parentSessionId === undefined) return {}
  if (parseRemoteSessionKey(parentSessionId) !== undefined) {
    return botFromFleet(services, serverId, parentSessionId, verified)
  }
  return (await run(services.db.findBotLinkForSession(parentSessionId))) ?? {}
}

export const assertMayJoinWorkspace = async (
  services: CodevisorServerServices,
  workspaceId: string | undefined,
  parentSessionId: string | undefined,
  verified: VerifiedRemoteParent | undefined
): Promise<void> => {
  if (workspaceId === undefined || parentSessionId === undefined) return
  const owner = await remoteBotOf(services, workspaceId)
  if (owner === undefined) return
  if (await joinsBotTree(services, owner, parentSessionId, verified)) return
  throw new HttpFailure(409, "This workspace belongs to a bot on another machine")
}

export const assertNotMovingIntoRemoteBot = async (
  services: CodevisorServerServices,
  workspaceId: string
): Promise<void> => {
  if ((await remoteBotOf(services, workspaceId)) === undefined) return
  throw new HttpFailure(
    409,
    "Chats can't move into a workspace that belongs to a bot on another machine"
  )
}

interface RemoteBotOwner {
  readonly bot: BotLink
  readonly parentSessionId: string | undefined
}

const remoteBotOf = async (
  services: CodevisorServerServices,
  workspaceId: string
): Promise<RemoteBotOwner | undefined> => {
  const workspace = (await run(services.db.listWorkspaces)).find(
    (candidate) => candidate.id === workspaceId.toLowerCase()
  )
  if (workspace?.botId === undefined || workspace.botMachineId === undefined) return undefined
  const recorded = await run(services.db.findWorkspaceFleetBotLink(workspace.id))
  return {
    bot: { botId: workspace.botId, botMachineId: workspace.botMachineId },
    parentSessionId: recorded?.parentSessionId
  }
}

const joinsBotTree = async (
  services: CodevisorServerServices,
  owner: RemoteBotOwner,
  parentSessionId: string,
  verified: VerifiedRemoteParent | undefined
): Promise<boolean> => {
  if (parseRemoteSessionKey(parentSessionId) !== undefined) {
    return verified !== undefined && owner.parentSessionId === parentSessionId
  }
  const link = await run(services.db.findBotLinkForSession(parentSessionId))
  return link?.botId === owner.bot.botId && link.botMachineId === owner.bot.botMachineId
}

const botFromFleet = async (
  services: CodevisorServerServices,
  serverId: string,
  parentSessionId: string,
  verified: VerifiedRemoteParent | undefined
): Promise<WorkspaceBotFields> => {
  const bot = verified?.bot
  if (bot === undefined) return {}
  if (bot.botMachineId !== serverId) return { ...bot, botParentSessionId: parentSessionId }

  const local = await run(services.db.getBot(bot.botId))
  return local === undefined ? {} : { botId: local.id }
}

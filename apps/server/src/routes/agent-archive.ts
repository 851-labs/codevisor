import {
  ArchiveAgentRequest,
  type ArchivedAgent,
  type SessionSummary,
  type Workspace
} from "@codevisor/api"

import { archiveChatAndOwned, archiveWorkspaceNow } from "../archive-jobs.js"
import { readSchema, run, writeJson } from "../server-context.js"
import { currentState } from "./agent-lifecycle.js"
import { assertNotOwnedByBot, refuseBotAsAgent } from "./bot-guards.js"
import type { RouteContext } from "./route-context.js"
import {
  archiveContextOf,
  callerOf,
  deferChatArchive,
  deferWorkspaceArchive,
  type ScheduledArchive
} from "./self-archive.js"
import { cancelTurn } from "./session-actions.js"
import { findWorkspace, sameId } from "./workspace-lookups.js"

export const archiveAgent = async (route: RouteContext, agentId: string): Promise<boolean> => {
  const { callerAgentId } = await readSchema(route.request, ArchiveAgentRequest)
  const agent = await run(route.services.db.getSessionSummary(agentId))
  await refuseBotAsAgent(route.services, agent.id, "archive")
  const caller = await callerOf(route, callerAgentId)

  if (isSelf(agent, caller))
    return respond(route, { agentId: agent.id, ...(await archiveSelf(route, agent)) })

  const own = await ownWorkspaceOf(route, agent, caller)
  if (own === undefined) await archiveChat(route, agent, caller)
  else await archiveOwnWorkspace(route, own)
  return respond(route, { agentId: agent.id, archived: true })
}

const respond = (route: RouteContext, body: ArchivedAgent): boolean => {
  writeJson(route.response, 200, body)
  return true
}

const isSelf = (agent: SessionSummary, caller: SessionSummary | undefined): boolean =>
  caller !== undefined && sameId(agent.id, caller.id)

const archiveSelf = async (
  route: RouteContext,
  agent: SessionSummary
): Promise<ScheduledArchive> => {
  const own = await ownWorkspaceOf(route, agent, undefined)
  if (own === undefined) return deferChatArchive(route, agent)

  await assertNotOwnedByBot(route.services, { workspaceId: own.id }, "archive this agent")
  return deferWorkspaceArchive(route, agent, own)
}

const ownWorkspaceOf = async (
  { services }: RouteContext,
  agent: SessionSummary,
  caller: SessionSummary | undefined
): Promise<Workspace | undefined> => {
  if (agent.workspaceId === undefined || sharesWorkspace(agent.workspaceId, caller))
    return undefined
  const workspace = await findWorkspace(services, agent.workspaceId)
  if (workspace === undefined || isSideChat(workspace, agent)) return undefined
  return workspace
}

const sharesWorkspace = (workspaceId: string, caller: SessionSummary | undefined): boolean =>
  caller?.workspaceId !== undefined && sameId(workspaceId, caller.workspaceId)

const isSideChat = (workspace: Workspace, agent: SessionSummary): boolean =>
  workspace.mainSessionId !== undefined && !sameId(workspace.mainSessionId, agent.id)

const archiveOwnWorkspace = async (route: RouteContext, workspace: Workspace): Promise<void> => {
  await assertNotOwnedByBot(route.services, { workspaceId: workspace.id }, "archive this agent")
  await archiveWorkspaceNow(archiveContextOf(route), workspace)
}

const archiveChat = async (
  route: RouteContext,
  agent: SessionSummary,
  caller: SessionSummary | undefined
): Promise<void> => {
  if (caller !== undefined) await unsubscribeCaller(route, caller.id, agent.id)
  if (await isRunning(route, agent)) await cancelTurn(route, agent.id)
  await archiveChatAndOwned(archiveContextOf(route), agent)
}

const unsubscribeCaller = async ({ services }: RouteContext, callerId: string, agentId: string) => {
  const held = await run(services.db.listSessionSubscriptions(callerId))
  for (const subscription of held.filter(({ targetSessionId }) => sameId(targetSessionId, agentId)))
    await run(services.db.deleteSessionSubscription(subscription.id))
}

const isRunning = async ({ services }: RouteContext, agent: SessionSummary) => {
  const state = await currentState(services, agent)
  return state === "working" || state === "waitingForUser"
}

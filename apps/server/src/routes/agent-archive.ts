import {
  ArchiveAgentRequest,
  type ArchivedAgent,
  type SessionSummary,
  type Workspace
} from "@codevisor/api"

import { reclaimArchivedChat } from "../archive-jobs.js"
import { appendAndPublish, HttpFailure, readSchema, run, writeJson } from "../server-context.js"
import { currentState } from "./agent-lifecycle.js"
import { assertNotOwnedByBot } from "./bot-guards.js"
import { publishPromptQueue } from "./prompt-queue.js"
import type { RouteContext } from "./route-context.js"
import { cancelTurn } from "./session-actions.js"
import { findSession } from "./session-workspace.js"
import { archiveAndWait } from "./workspace-archive.js"
import { findWorkspace, sameId } from "./workspace-lookups.js"

export const archiveAgent = async (route: RouteContext, agentId: string): Promise<boolean> => {
  const { callerAgentId } = await readSchema(route.request, ArchiveAgentRequest)
  const agent = await run(route.services.db.getSessionSummary(agentId))
  const caller = await callerOf(route, callerAgentId)
  refuseSelf(agent, caller)

  const own = await ownWorkspaceOf(route, agent, caller)
  if (own === undefined) await archiveChat(route, agent, caller)
  else await archiveOwnWorkspace(route, own)

  const archived: ArchivedAgent = { agentId: agent.id, archived: true }
  writeJson(route.response, 200, archived)
  return true
}

const callerOf = async (
  { services }: RouteContext,
  callerAgentId: string | undefined
): Promise<SessionSummary | undefined> => {
  if (callerAgentId === undefined) return undefined
  const caller = await findSession(services.db, callerAgentId)
  if (caller === undefined) throw new HttpFailure(422, `Unknown caller: ${callerAgentId}`)
  return caller
}

const refuseSelf = (agent: SessionSummary, caller: SessionSummary | undefined): void => {
  if (caller === undefined || !sameId(agent.id, caller.id)) return
  throw new HttpFailure(
    422,
    `Agent ${agent.id} is you: you can't archive yourself. Finish your turn instead`
  )
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
  await archiveAndWait(route, workspace)
}

const archiveChat = async (
  route: RouteContext,
  agent: SessionSummary,
  caller: SessionSummary | undefined
): Promise<void> => {
  if (caller !== undefined) await unsubscribeCaller(route, caller.id, agent.id)
  await stopAgent(route, agent)
  await run(route.services.db.archiveSession(agent.id))
  await deleteChatPanes(route, agent.id)
  await reclaimArchivedChat(route.services, route.fanout, route.config, agent)
}

const unsubscribeCaller = async ({ services }: RouteContext, callerId: string, agentId: string) => {
  const held = await run(services.db.listSessionSubscriptions(callerId))
  for (const subscription of held.filter(({ targetSessionId }) => sameId(targetSessionId, agentId)))
    await run(services.db.deleteSessionSubscription(subscription.id))
}

const stopAgent = async (route: RouteContext, agent: SessionSummary): Promise<void> => {
  await clearPromptQueue(route, agent.id)
  if (await isRunning(route, agent)) await cancelTurn(route, agent.id)
}

const clearPromptQueue = async ({ services, fanout }: RouteContext, agentId: string) => {
  const queue = await run(services.db.listPromptQueue(agentId))
  if (queue.length === 0) return
  for (const item of queue) await run(services.db.deletePromptQueueItem(agentId, item.id))
  await publishPromptQueue(services.db, fanout, agentId)
}

const isRunning = async ({ services }: RouteContext, agent: SessionSummary) => {
  const state = await currentState(services, agent)
  return state === "working" || state === "waitingForUser"
}

const deleteChatPanes = async ({ services, fanout }: RouteContext, agentId: string) => {
  const panes = (await run(services.db.listWorkspacePanes)).filter(
    (pane) => pane.resourceKind === "session" && pane.resourceId === agentId
  )
  for (const pane of panes) {
    await run(services.db.deleteWorkspacePane(pane.workspaceId, pane.id))
    await appendAndPublish(services.db, fanout, "workspace.pane.deleted", pane.id, {
      id: pane.id,
      workspaceId: pane.workspaceId
    })
  }
}

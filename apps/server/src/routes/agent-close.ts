import { CloseAgentRequest, type ClosedAgent, type SessionSummary } from "@codevisor/api"

import { appendAndPublish, HttpFailure, readSchema, run, writeJson } from "../server-context.js"
import { currentState } from "./agent-lifecycle.js"
import { publishPromptQueue } from "./prompt-queue.js"
import type { RouteContext } from "./route-context.js"
import { cancelTurn } from "./session-actions.js"
import { findSession } from "./session-workspace.js"
import { sameId } from "./workspace-lookups.js"

export const closeAgent = async (route: RouteContext, agentId: string): Promise<boolean> => {
  const { callerAgentId } = await readSchema(route.request, CloseAgentRequest)
  const agent = await run(route.services.db.getSessionSummary(agentId))
  const caller = await knownCaller(route, callerAgentId)
  refuseSelf(agent, caller)
  const workspaceId = sharedWorkspaceOf(agent, caller)

  await unsubscribeCaller(route, caller.id, agent.id)
  await stopAgent(route, agent)
  await deleteChatPanes(route, agent.id)
  const closed: ClosedAgent = { agentId: agent.id, workspaceId, closed: true }
  writeJson(route.response, 200, closed)
  return true
}

const knownCaller = async ({ services }: RouteContext, callerAgentId: string) => {
  const caller = await findSession(services.db, callerAgentId)
  if (caller === undefined) throw new HttpFailure(422, `Unknown caller: ${callerAgentId}`)
  return caller
}

const refuseSelf = (agent: SessionSummary, caller: SessionSummary): void => {
  if (sameId(agent.id, caller.id)) {
    throw new HttpFailure(
      422,
      `Agent ${agent.id} is you: you can't close yourself. Finish your turn instead`
    )
  }
}

const sharedWorkspaceOf = (agent: SessionSummary, caller: SessionSummary): string => {
  const workspaceId = agent.workspaceId
  if (workspaceId === undefined || caller.workspaceId === undefined) throw notShared(agent)
  if (!sameId(workspaceId, caller.workspaceId)) throw notShared(agent)
  return workspaceId
}

const notShared = (agent: SessionSummary): HttpFailure =>
  new HttpFailure(
    422,
    `Agent ${agent.id} isn't in your workspace, so agents.close can't close it.${archiveHint(agent)}`
  )

const archiveHint = ({ workspaceId }: SessionSummary): string => {
  if (workspaceId === undefined) return ""
  return ` When you're done with its workspace, call workspaces.archive({ workspaceId: "${workspaceId}" })`
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

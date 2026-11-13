import { randomUUID } from "node:crypto"

import type { DetachedAgent, SessionSummary } from "@codevisor/api"

import { appendAndPublish, HttpFailure, run, writeJson } from "../server-context.js"
import { refuseBotAsAgent } from "./bot-guards.js"
import type { RouteContext } from "./route-context.js"
import { applySessionUpdate } from "./session-workspace.js"
import { findWorkspace, sameId } from "./workspace-lookups.js"

export const detachAgent = async (route: RouteContext, agentId: string): Promise<boolean> => {
  const { services, fanout, response } = route
  const agent = await run(services.db.getSessionSummary(agentId))
  await refuseBotAsAgent(services, agent.id, "detach")
  if (agent.createdByAgentId === undefined) {
    throw new HttpFailure(
      422,
      `Agent ${agent.id} was not started by another agent, so it already stands alone`
    )
  }

  if (await lacksItsOwnWorkspace(route, agent)) {
    await applySessionUpdate(services, fanout, agent.id, { workspaceId: randomUUID() })
  }
  await run(services.db.detachSession(agent.id))
  const standing = await run(services.db.getSessionSummary(agent.id))
  await appendAndPublish(services.db, fanout, "session.updated", standing.id, standing)

  const detached: DetachedAgent = {
    agentId: standing.id,
    ...(standing.workspaceId === undefined ? {} : { workspaceId: standing.workspaceId }),
    detached: true
  }
  writeJson(response, 200, detached)
  return true
}

const lacksItsOwnWorkspace = async (
  { services }: RouteContext,
  agent: SessionSummary
): Promise<boolean> => {
  if (agent.workspaceId === undefined) return true
  const workspace = await findWorkspace(services, agent.workspaceId)
  return workspace?.mainSessionId !== undefined && !sameId(workspace.mainSessionId, agent.id)
}

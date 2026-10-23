import { randomUUID } from "node:crypto"
import type { IncomingMessage, ServerResponse } from "node:http"

import {
  CreateWorkspaceRequest as CreateWorkspaceRequestSchema,
  type CreateSessionRequest
} from "@codevisor/api"

import {
  appendAndPublish,
  getProjectOrFail,
  HttpFailure,
  readSchema,
  run,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import {
  assertMayJoinWorkspace,
  assertNotMovingIntoRemoteBot,
  botForParentSession
} from "./bot-guards.js"
import { assertRemoteParentVerified } from "./fleet-calls.js"
import { resolveSessionAccount, startSessionAgent, withStartPicks } from "./session-creation.js"
import { findSession, resolveSessionCwdOrFail } from "./session-workspace.js"

export const routeWorkspaceCreate = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (request.method !== "POST" || url.pathname !== "/v1/workspaces") return false
  const payload = await readSchema(request, CreateWorkspaceRequestSchema)
  if (payload.workspace.id === undefined) {
    throw new HttpFailure(400, "Workspace id is required")
  }
  const project = await getProjectOrFail(services.db, payload.session.projectId)
  if (payload.workspace.projectId.toLowerCase() !== project.id.toLowerCase()) {
    throw new HttpFailure(409, "Chat and workspace must belong to the same project")
  }
  const workspaceId = payload.workspace.id.toLowerCase()
  assertRemoteParentVerified(payload.session.parentSessionId, undefined)
  await assertMayJoinWorkspace(services, workspaceId, payload.session.parentSessionId, undefined)
  const sessionId = (payload.session.id ?? randomUUID()).toLowerCase()
  const existing = await findSession(services.db, sessionId)
  if (existing !== undefined && existing.workspaceId !== workspaceId) {
    await assertNotMovingIntoRemoteBot(services, workspaceId)
  }
  let sessionPayload: CreateSessionRequest = {
    ...payload.session,
    id: sessionId,
    projectId: project.id
  }
  if (existing === undefined) {
    sessionPayload = await withStartPicks(services, sessionPayload)
    const cwd = await resolveSessionCwdOrFail(
      services,
      config.id,
      project,
      payload.session.worktreeName
    )
    const { accountContext, harnessAccountId } = await resolveSessionAccount(
      services,
      payload.session
    )
    const agentSessionId = await startSessionAgent(
      services,
      fanout,
      config.id,
      sessionId,
      project,
      sessionPayload,
      cwd,
      accountContext
    )
    sessionPayload = {
      ...sessionPayload,
      /* v8 ignore next */
      ...(harnessAccountId === undefined ? {} : { harnessAccountId }),
      agentSessionId
    }
  }
  const created = await run(
    services.db.createWorkspaceWithSession({
      workspace: {
        ...payload.workspace,
        ...(await botForParentSession(services, config.id, payload.session.parentSessionId)),
        id: workspaceId,
        projectId: project.id
      },
      session: sessionPayload,
      ...(payload.pane === undefined ? {} : { pane: payload.pane })
    })
  )
  await appendAndPublish(
    services.db,
    fanout,
    "workspace.updated",
    created.workspace.id,
    created.workspace
  )
  await appendAndPublish(
    services.db,
    fanout,
    existing === undefined ? "session.created" : "session.updated",
    created.session.id,
    created.session
  )
  await appendAndPublish(
    services.db,
    fanout,
    "workspace.pane.updated",
    created.pane.id,
    created.pane
  )
  writeJson(response, existing === undefined ? 201 : 200, created)
  return true
}

import { randomUUID } from "node:crypto"
import type { IncomingMessage, ServerResponse } from "node:http"

import { CreateWorkspaceRequest as CreateWorkspaceRequestSchema } from "@codevisor/api"

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
import { resolveSessionAccount, startSessionAgent } from "./session-creation.js"
import { findSession, resolveSessionCwdOrFail } from "./session-workspace.js"

/// POST /v1/workspaces — a workspace born around its first chat. The
/// workspace row, the session row and the chat pane commit in one database
/// transaction, so the navigation journal publishes them as one change and
/// no client ever sees the workspace without its chat. Everything that lives
/// outside the database (cwd, account, provider session) is prepared first,
/// exactly as the discrete POST /v1/sessions does.
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
  const sessionId = (payload.session.id ?? randomUUID()).toLowerCase()
  const existing = await findSession(services.db, sessionId)
  let sessionPayload = { ...payload.session, id: sessionId, projectId: project.id }
  if (existing === undefined) {
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
      payload.session,
      cwd,
      accountContext
    )
    sessionPayload = {
      ...sessionPayload,
      /* v8 ignore next -- account binding is integration-tested through POST /v1/sessions, which shares resolveSessionAccount. */
      ...(harnessAccountId === undefined ? {} : { harnessAccountId }),
      agentSessionId
    }
  }
  const created = await run(
    services.db.createWorkspaceWithSession({
      workspace: { ...payload.workspace, id: workspaceId, projectId: project.id },
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

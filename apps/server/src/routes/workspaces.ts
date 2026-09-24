import type { IncomingMessage, ServerResponse } from "node:http"

import {
  PromoteWorkspacePaneToChatRequest as PromoteWorkspacePaneToChatRequestSchema,
  UpdateWorkspacePaneRequest as UpdateWorkspacePaneRequestSchema,
  UpdateWorkspaceRequest as UpdateWorkspaceRequestSchema,
  UpsertWorkspacePaneRequest as UpsertWorkspacePaneRequestSchema,
  UpsertWorkspaceRequest as UpsertWorkspaceRequestSchema
} from "@codevisor/api"

import {
  appendAndPublish,
  applyWorkspaceArchiveEffects,
  HttpFailure,
  matchRoute,
  matchRouteParams,
  readSchema,
  run,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { createSessionIfMissing } from "./session-workspace.js"
import { routeWorkspaceCreate } from "./workspace-create.js"

/// Pane workspaces are client-authored identity records, so writes are
/// idempotent PUTs keyed by the client's workspace id. Creates and updates
/// share one `workspace.updated` event to keep client mirroring simple.
export const routeWorkspaces = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  config: CodevisorServerConfig,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (request.method === "GET" && url.pathname === "/v1/workspaces") {
    writeJson(response, 200, await run(services.db.listWorkspaces))
    return true
  }

  if (await routeWorkspaceCreate(services, fanout, config, request, response, url)) {
    return true
  }

  if (request.method === "GET" && url.pathname === "/v1/workspace-snapshot") {
    writeJson(response, 200, await run(services.db.getWorkspaceSnapshot))
    return true
  }

  if (request.method === "GET" && url.pathname === "/v1/workspace-panes") {
    writeJson(response, 200, await run(services.db.listWorkspacePanes))
    return true
  }

  const promoteRoute = matchRouteParams(
    url.pathname,
    "/v1/workspaces/:workspaceId/panes/:paneId/promote-chat"
  )
  if (promoteRoute !== undefined && request.method === "POST") {
    const payload = await readSchema(request, PromoteWorkspacePaneToChatRequestSchema)
    const workspaceId = promoteRoute.workspaceId as string
    const paneId = promoteRoute.paneId as string
    const workspace = (await run(services.db.listWorkspaces)).find(
      (candidate) => candidate.id.toLowerCase() === workspaceId.toLowerCase()
    )
    if (workspace === undefined) throw new HttpFailure(404, "Workspace not found")
    const existingPane = (await run(services.db.listWorkspacePanes)).find(
      (candidate) =>
        candidate.id.toLowerCase() === paneId.toLowerCase() &&
        candidate.workspaceId.toLowerCase() === workspaceId.toLowerCase()
    )
    if (existingPane === undefined) throw new HttpFailure(404, "Workspace pane not found")
    if (workspace.projectId.toLowerCase() !== payload.session.projectId.toLowerCase()) {
      throw new HttpFailure(409, "Chat and workspace must belong to the same project")
    }
    const { session: ensured, created } = await createSessionIfMissing(
      services,
      fanout,
      routeState,
      config,
      { ...payload.session, workspaceId: undefined },
      false
    )
    const pane = await run(
      services.db.promoteWorkspacePaneToSession(
        workspaceId,
        paneId,
        ensured.id,
        payload.title ?? (ensured.title || "New Chat")
      )
    )
    const session = await run(services.db.getSessionSummary(ensured.id))
    await appendAndPublish(
      services.db,
      fanout,
      created ? "session.created" : "session.updated",
      session.id,
      session
    )
    await appendAndPublish(services.db, fanout, "workspace.pane.updated", pane.id, pane)
    writeJson(response, created ? 201 : 200, { pane, session })
    return true
  }

  const paneRoute = matchRouteParams(url.pathname, "/v1/workspaces/:workspaceId/panes/:paneId")
  const closeRoute = matchRouteParams(
    url.pathname,
    "/v1/workspaces/:workspaceId/panes/:paneId/close"
  )
  // Close and DELETE are the same operation. Closing the last pane leaves the
  // workspace empty; the response keeps its `{ pane }` shape (always absent
  // now) for clients that predate that.
  if (
    (closeRoute !== undefined && request.method === "POST") ||
    (paneRoute !== undefined && request.method === "DELETE")
  ) {
    const route = (closeRoute ?? paneRoute)!
    await run(services.db.deleteWorkspacePane(route.workspaceId as string, route.paneId as string))
    await appendAndPublish(services.db, fanout, "workspace.pane.deleted", route.paneId as string, {
      id: route.paneId,
      workspaceId: route.workspaceId
    })
    writeJson(response, 200, {})
    return true
  }

  if (paneRoute !== undefined && request.method === "PUT") {
    const payload = await readSchema(request, UpsertWorkspacePaneRequestSchema)
    if (payload.id !== undefined && payload.id.toLowerCase() !== paneRoute.paneId?.toLowerCase()) {
      throw new HttpFailure(
        400,
        `Pane id in the body (${payload.id}) does not match the path (${paneRoute.paneId})`
      )
    }
    const pane = await run(
      services.db.upsertWorkspacePane(paneRoute.workspaceId as string, {
        ...payload,
        id: paneRoute.paneId as string
      })
    )
    await appendAndPublish(services.db, fanout, "workspace.pane.updated", pane.id, pane)
    writeJson(response, 200, pane)
    return true
  }

  if (paneRoute !== undefined && request.method === "PATCH") {
    const payload = await readSchema(request, UpdateWorkspacePaneRequestSchema)
    const pane = await run(
      services.db.updateWorkspacePane(
        paneRoute.workspaceId as string,
        paneRoute.paneId as string,
        payload
      )
    )
    await appendAndPublish(services.db, fanout, "workspace.pane.updated", pane.id, pane)
    writeJson(response, 200, pane)
    return true
  }

  const workspaceId = matchRoute(url.pathname, "/v1/workspaces/:id")
  if (workspaceId !== undefined && request.method === "PUT") {
    const payload = await readSchema(request, UpsertWorkspaceRequestSchema)
    // UUID comparison is case-insensitive: the path id is canonicalized to
    // lowercase while Swift clients send uppercase body ids.
    if (payload.id !== undefined && payload.id.toLowerCase() !== workspaceId.toLowerCase()) {
      throw new HttpFailure(
        400,
        `Workspace id in the body (${payload.id}) does not match the path (${workspaceId})`
      )
    }
    const wasArchived = (await run(services.db.listWorkspaces)).some(
      (candidate) =>
        candidate.id.toLowerCase() === workspaceId.toLowerCase() && candidate.isArchived
    )
    const workspace = await run(services.db.upsertWorkspace({ ...payload, id: workspaceId }))
    // A PUT can flip the archive bit exactly like the PATCH below, so it owes
    // the same teardown/restore.
    const settled = await applyWorkspaceArchiveEffects(
      services,
      fanout,
      config,
      workspace,
      wasArchived
    )
    writeJson(response, 200, settled)
    return true
  }

  if (workspaceId !== undefined && request.method === "PATCH") {
    const payload = await readSchema(request, UpdateWorkspaceRequestSchema)
    const wasArchived = (await run(services.db.listWorkspaces)).some(
      (candidate) =>
        candidate.id.toLowerCase() === workspaceId.toLowerCase() && candidate.isArchived
    )
    const workspace = await run(services.db.updateWorkspace(workspaceId, payload))
    const settled = await applyWorkspaceArchiveEffects(
      services,
      fanout,
      config,
      workspace,
      wasArchived
    )
    writeJson(response, 200, settled)
    return true
  }

  if (workspaceId !== undefined && request.method === "DELETE") {
    const wasArchived = (await run(services.db.listWorkspaces)).some(
      (candidate) =>
        candidate.id.toLowerCase() === workspaceId.toLowerCase() && candidate.isArchived
    )
    const workspace = await run(services.db.updateWorkspace(workspaceId, { isArchived: true }))
    await applyWorkspaceArchiveEffects(services, fanout, config, workspace, wasArchived)
    // `sessions.workspace_id` has no ON DELETE clause and foreign keys are
    // enforced, so the chats must let go of the workspace before it can be
    // dropped -- otherwise this raises after the worktree is already gone.
    for (const session of await run(services.db.listSessions)) {
      if (session.workspaceId?.toLowerCase() !== workspaceId.toLowerCase()) continue
      await run(services.db.setSessionWorkspace(session.id, null))
    }
    await run(services.db.deleteWorkspace(workspaceId))
    await appendAndPublish(services.db, fanout, "workspace.deleted", workspaceId, {
      id: workspaceId
    })
    writeJson(response, 204, undefined)
    return true
  }

  return false
}

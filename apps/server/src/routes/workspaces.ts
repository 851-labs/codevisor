import type { IncomingMessage, ServerResponse } from "node:http"

import {
  PromoteWorkspacePaneToChatRequest as PromoteWorkspacePaneToChatRequestSchema,
  UpdateWorkspacePaneRequest as UpdateWorkspacePaneRequestSchema,
  UpdateWorkspaceRequest as UpdateWorkspaceRequestSchema,
  UpsertWorkspacePaneRequest as UpsertWorkspacePaneRequestSchema,
  UpsertWorkspaceRequest as UpsertWorkspaceRequestSchema,
  type Workspace
} from "@codevisor/api"

import {
  appendAndPublish,
  applyWorkspaceArchiveEffects,
  captureWorkspaceRuntime,
  enqueueWorkspaceArchive,
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

/// The workspace with this id, or undefined. Route handlers use it to answer
/// a retried or stale request with its real outcome -- gone is 404 for an
/// edit and a completed no-op for a delete -- instead of a 500 from the
/// database layer. Clients retry requests from an outbox, so every mutation
/// here has to be safe to receive twice.
const findWorkspace = async (
  services: CodevisorServerServices,
  workspaceId: string
): Promise<Workspace | undefined> =>
  (await run(services.db.listWorkspaces)).find(
    (candidate) => candidate.id.toLowerCase() === workspaceId.toLowerCase()
  )

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
    if ((await findWorkspace(services, route.workspaceId as string)) === undefined) {
      writeJson(response, 200, {})
      return true
    }
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
    if ((await findWorkspace(services, paneRoute.workspaceId as string)) === undefined) {
      throw new HttpFailure(404, `Workspace not found: ${paneRoute.workspaceId}`)
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
    const panes = await run(services.db.listWorkspacePanes)
    if (
      !panes.some(
        (candidate) =>
          candidate.id.toLowerCase() === (paneRoute.paneId as string).toLowerCase() &&
          candidate.workspaceId.toLowerCase() === (paneRoute.workspaceId as string).toLowerCase()
      )
    ) {
      throw new HttpFailure(404, `Workspace pane not found: ${paneRoute.paneId}`)
    }
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
      routeState,
      workspace,
      wasArchived
    )
    writeJson(response, 200, settled)
    return true
  }

  if (workspaceId !== undefined && request.method === "PATCH") {
    const payload = await readSchema(request, UpdateWorkspaceRequestSchema)
    const existing = await findWorkspace(services, workspaceId)
    if (existing === undefined) {
      throw new HttpFailure(404, `Workspace not found: ${workspaceId}`)
    }
    const wasArchived = existing.isArchived
    // A sidebarOrder whose expectedRevision is stale is answered with the
    // current row and no change; the client then shows the server's order.
    const workspace = await run(services.db.updateWorkspace(workspaceId, payload))
    const settled = await applyWorkspaceArchiveEffects(
      services,
      fanout,
      config,
      routeState,
      workspace,
      wasArchived
    )
    writeJson(response, 200, settled)
    return true
  }

  if (workspaceId !== undefined && request.method === "DELETE") {
    const existing = await findWorkspace(services, workspaceId)
    if (existing === undefined) {
      writeJson(response, 204, undefined)
      return true
    }
    const workspace = await run(services.db.updateWorkspace(workspaceId, { isArchived: true }))
    await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, workspace)
    // Read what the workspace runs before its chats and panes let go of it;
    // the teardown itself is queued once the workspace is gone. A workspace
    // that was already archived is torn down again, which is a no-op after a
    // finished archive and a retry after a failed one.
    const runtime = await captureWorkspaceRuntime(services, routeState, workspace)
    // `sessions.workspace_id` has no ON DELETE clause and foreign keys are
    // enforced, so the chats must let go of the workspace before it can be
    // dropped.
    for (const session of await run(services.db.listSessions)) {
      if (session.workspaceId?.toLowerCase() !== workspaceId.toLowerCase()) continue
      await run(services.db.setSessionWorkspace(session.id, null))
    }
    await run(services.db.deleteWorkspace(workspaceId))
    await appendAndPublish(services.db, fanout, "workspace.deleted", workspaceId, {
      id: workspaceId
    })
    void enqueueWorkspaceArchive(services, fanout, config, workspace, runtime)
    writeJson(response, 204, undefined)
    return true
  }

  return false
}

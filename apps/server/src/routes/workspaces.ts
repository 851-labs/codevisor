import type { IncomingMessage, ServerResponse } from "node:http"

import {
  PromoteWorkspacePaneToChatRequest as PromoteWorkspacePaneToChatRequestSchema,
  ReorderWorkspacePanesRequest as ReorderWorkspacePanesRequestSchema,
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
import { matchesLabelFilters } from "./label-filters.js"
import { routeParam } from "./route-params.js"
import { createSessionIfMissing } from "./session-workspace.js"
import { routeWorkspaceCreate } from "./workspace-create.js"

const findWorkspace = async (
  services: CodevisorServerServices,
  workspaceId: string
): Promise<Workspace | undefined> =>
  (await run(services.db.listWorkspaces)).find(
    (candidate) => candidate.id.toLowerCase() === workspaceId.toLowerCase()
  )

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
    writeJson(
      response,
      200,
      (await run(services.db.listWorkspaces)).filter((workspace) =>
        matchesLabelFilters(workspace.labels, url)
      )
    )
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
    const workspaceId = routeParam(promoteRoute, "workspaceId")
    const paneId = routeParam(promoteRoute, "paneId")
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

  const reorderRoute = matchRouteParams(url.pathname, "/v1/workspaces/:workspaceId/panes/reorder")
  if (reorderRoute !== undefined && request.method === "POST") {
    const payload = await readSchema(request, ReorderWorkspacePanesRequestSchema)
    const workspaceId = routeParam(reorderRoute, "workspaceId")
    if ((await findWorkspace(services, workspaceId)) === undefined) {
      throw new HttpFailure(404, `Workspace not found: ${workspaceId}`)
    }
    const panes = await run(services.db.reorderWorkspacePanes(workspaceId, payload.paneIds))
    for (const pane of panes) {
      await appendAndPublish(services.db, fanout, "workspace.pane.updated", pane.id, pane)
    }
    writeJson(response, 200, panes)
    return true
  }

  const paneRoute = matchRouteParams(url.pathname, "/v1/workspaces/:workspaceId/panes/:paneId")
  const closeRoute = matchRouteParams(
    url.pathname,
    "/v1/workspaces/:workspaceId/panes/:paneId/close"
  )
  if (
    (closeRoute !== undefined && request.method === "POST") ||
    (paneRoute !== undefined && request.method === "DELETE")
  ) {
    const route = (closeRoute ?? paneRoute)!
    const workspaceId = routeParam(route, "workspaceId")
    const paneId = routeParam(route, "paneId")
    if ((await findWorkspace(services, workspaceId)) === undefined) {
      writeJson(response, 200, {})
      return true
    }
    await run(services.db.deleteWorkspacePane(workspaceId, paneId))
    await appendAndPublish(services.db, fanout, "workspace.pane.deleted", paneId, {
      id: paneId,
      workspaceId
    })
    writeJson(response, 200, {})
    return true
  }

  if (paneRoute !== undefined && request.method === "PUT") {
    const payload = await readSchema(request, UpsertWorkspacePaneRequestSchema)
    const workspaceId = routeParam(paneRoute, "workspaceId")
    const paneId = routeParam(paneRoute, "paneId")
    if (payload.id !== undefined && payload.id.toLowerCase() !== paneId.toLowerCase()) {
      throw new HttpFailure(
        400,
        `Pane id in the body (${payload.id}) does not match the path (${paneId})`
      )
    }
    if ((await findWorkspace(services, workspaceId)) === undefined) {
      throw new HttpFailure(404, `Workspace not found: ${workspaceId}`)
    }
    const pane = await run(services.db.upsertWorkspacePane(workspaceId, { ...payload, id: paneId }))
    await appendAndPublish(services.db, fanout, "workspace.pane.updated", pane.id, pane)
    writeJson(response, 200, pane)
    return true
  }

  if (paneRoute !== undefined && request.method === "PATCH") {
    const payload = await readSchema(request, UpdateWorkspacePaneRequestSchema)
    const workspaceId = routeParam(paneRoute, "workspaceId")
    const paneId = routeParam(paneRoute, "paneId")
    const panes = await run(services.db.listWorkspacePanes)
    if (
      !panes.some(
        (candidate) =>
          candidate.id.toLowerCase() === paneId.toLowerCase() &&
          candidate.workspaceId.toLowerCase() === workspaceId.toLowerCase()
      )
    ) {
      throw new HttpFailure(404, `Workspace pane not found: ${paneId}`)
    }
    const pane = await run(services.db.updateWorkspacePane(workspaceId, paneId, payload))
    await appendAndPublish(services.db, fanout, "workspace.pane.updated", pane.id, pane)
    writeJson(response, 200, pane)
    return true
  }

  const workspaceId = matchRoute(url.pathname, "/v1/workspaces/:id")
  if (workspaceId !== undefined && request.method === "PUT") {
    const payload = await readSchema(request, UpsertWorkspaceRequestSchema)
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
    const runtime = await captureWorkspaceRuntime(services, routeState, workspace)
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

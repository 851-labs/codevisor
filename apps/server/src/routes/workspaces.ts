import {
  PromoteWorkspacePaneToChatRequest as PromoteWorkspacePaneToChatRequestSchema,
  UpdateWorkspacePaneRequest as UpdateWorkspacePaneRequestSchema,
  UpdateWorkspaceRequest as UpdateWorkspaceRequestSchema,
  UpsertWorkspacePaneRequest as UpsertWorkspacePaneRequestSchema,
  UpsertWorkspaceRequest as UpsertWorkspaceRequestSchema
} from "@codevisor/api"
import type { IncomingMessage, ServerResponse } from "node:http"
import {
  appendAndPublish,
  applyCascadedSessionEffects,
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
  if (closeRoute !== undefined && request.method === "POST") {
    const pane = await run(
      services.db.deleteWorkspacePane(closeRoute.workspaceId as string, closeRoute.paneId as string)
    )
    if (pane !== undefined) {
      await appendAndPublish(services.db, fanout, "workspace.pane.updated", pane.id, pane)
    } else {
      await appendAndPublish(
        services.db,
        fanout,
        "workspace.pane.deleted",
        closeRoute.paneId as string,
        { id: closeRoute.paneId, workspaceId: closeRoute.workspaceId }
      )
    }
    writeJson(response, 200, { pane })
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

  if (paneRoute !== undefined && request.method === "DELETE") {
    const pane = await run(
      services.db.deleteWorkspacePane(paneRoute.workspaceId as string, paneRoute.paneId as string)
    )
    if (pane !== undefined) {
      await appendAndPublish(services.db, fanout, "workspace.pane.updated", pane.id, pane)
    } else {
      await appendAndPublish(
        services.db,
        fanout,
        "workspace.pane.deleted",
        paneRoute.paneId as string,
        {
          id: paneRoute.paneId,
          workspaceId: paneRoute.workspaceId
        }
      )
    }
    writeJson(response, 200, { pane })
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
    const sessionsBefore = await run(services.db.listSessions)
    const workspace = await run(services.db.upsertWorkspace({ ...payload, id: workspaceId }))
    await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, workspace)
    // A PUT can flip the archive bit exactly like the PATCH below, so it owes
    // the same teardown/restore.
    await applyCascadedSessionEffects(services, fanout, config, sessionsBefore)
    writeJson(response, 200, workspace)
    return true
  }

  if (workspaceId !== undefined && request.method === "PATCH") {
    const payload = await readSchema(request, UpdateWorkspaceRequestSchema)
    const sessionsBefore =
      payload.isArchived === undefined ? [] : await run(services.db.listSessions)
    const workspace = await run(services.db.updateWorkspace(workspaceId, payload))
    await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, workspace)
    if (payload.isArchived !== undefined) {
      await applyCascadedSessionEffects(services, fanout, config, sessionsBefore)
    }
    writeJson(response, 200, workspace)
    return true
  }

  if (workspaceId !== undefined && request.method === "DELETE") {
    await run(services.db.deleteWorkspace(workspaceId))
    await appendAndPublish(services.db, fanout, "workspace.deleted", workspaceId, {
      id: workspaceId
    })
    writeJson(response, 204, undefined)
    return true
  }

  return false
}

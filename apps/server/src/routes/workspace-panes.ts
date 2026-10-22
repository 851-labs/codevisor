import type { IncomingMessage } from "node:http"

import type {
  CreateSessionRequest,
  EventEnvelope,
  PromoteWorkspacePaneToChatRequest,
  SessionSummary,
  Workspace,
  WorkspacePane
} from "@codevisor/api"
import {
  PromoteWorkspacePaneToChatRequest as PromoteWorkspacePaneToChatRequestSchema,
  ReorderWorkspacePanesRequest as ReorderWorkspacePanesRequestSchema,
  UpdateWorkspacePaneRequest as UpdateWorkspacePaneRequestSchema,
  UpsertWorkspacePaneRequest as UpsertWorkspacePaneRequestSchema
} from "@codevisor/api"

import {
  appendAndPublish,
  HttpFailure,
  matchRouteParams,
  readSchema,
  run,
  writeJson
} from "../server-context.js"
import type { RouteContext } from "./route-context.js"
import { routeParam } from "./route-params.js"
import { createSessionIfMissing } from "./session-workspace.js"
import {
  findWorkspace,
  refuseMismatchedBodyId,
  requireWorkspace,
  sameId,
  workspaceWithId
} from "./workspace-lookups.js"

type RouteParams = Readonly<Record<string, string>>

interface PaneIds {
  readonly workspaceId: string
  readonly paneId: string
}

interface EnsuredChat {
  readonly session: SessionSummary
  readonly created: boolean
}

export const routeWorkspacePanes = (route: RouteContext): Promise<boolean> | undefined => {
  const { request, url } = route
  if (request.method === "GET" && url.pathname === "/v1/workspace-panes") return listPanes(route)

  const promoteRoute = matchRouteParams(
    url.pathname,
    "/v1/workspaces/:workspaceId/panes/:paneId/promote-chat"
  )
  if (promoteRoute !== undefined && request.method === "POST")
    return promotePaneToChat(route, promoteRoute)

  const reorderRoute = matchRouteParams(url.pathname, "/v1/workspaces/:workspaceId/panes/reorder")
  if (reorderRoute !== undefined && request.method === "POST")
    return reorderPanes(route, reorderRoute)

  const paneRoute = matchRouteParams(url.pathname, "/v1/workspaces/:workspaceId/panes/:paneId")
  const closeRoute = matchRouteParams(
    url.pathname,
    "/v1/workspaces/:workspaceId/panes/:paneId/close"
  )
  const closedPaneRoute = paneToClose(request, closeRoute, paneRoute)
  if (closedPaneRoute !== undefined) return closePane(route, closedPaneRoute)
  if (paneRoute !== undefined && request.method === "PUT") return upsertPane(route, paneRoute)
  if (paneRoute !== undefined && request.method === "PATCH") return updatePane(route, paneRoute)
  return undefined
}

const listPanes = async ({ services, response }: RouteContext): Promise<boolean> => {
  writeJson(response, 200, await run(services.db.listWorkspacePanes))
  return true
}

const promotePaneToChat = async (route: RouteContext, params: RouteParams): Promise<boolean> => {
  const { services, request, response } = route
  const payload = await readSchema(request, PromoteWorkspacePaneToChatRequestSchema)
  const ids = paneIds(params)
  const workspace = promotedWorkspace(await run(services.db.listWorkspaces), ids)

  requirePromotedPane(await run(services.db.listWorkspacePanes), ids)

  refuseCrossProjectChat(workspace, payload)

  const { session: ensured, created } = await ensureChat(route, payload.session)
  const pane = await promotePane(route, ids, ensured, payload)
  const session = await run(services.db.getSessionSummary(ensured.id))
  await publishSession(route, chatEventKind(created), session)
  await publishPaneUpdated(route, pane)
  writeJson(response, created ? 201 : 200, { pane, session })
  return true
}

const reorderPanes = async (route: RouteContext, params: RouteParams): Promise<boolean> => {
  const { services, request, response } = route
  const payload = await readSchema(request, ReorderWorkspacePanesRequestSchema)
  const workspaceId = routeParam(params, "workspaceId")
  requireWorkspace(await findWorkspace(services, workspaceId), workspaceId)

  const panes = await run(services.db.reorderWorkspacePanes(workspaceId, payload.paneIds))
  for (const pane of panes) {
    await publishPaneUpdated(route, pane)
  }
  writeJson(response, 200, panes)
  return true
}

const closePane = async (route: RouteContext, params: RouteParams): Promise<boolean> => {
  const { services, fanout, response } = route
  const { workspaceId, paneId } = paneIds(params)
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

const upsertPane = async (route: RouteContext, params: RouteParams): Promise<boolean> => {
  const { services, request, response } = route
  const payload = await readSchema(request, UpsertWorkspacePaneRequestSchema)
  const { workspaceId, paneId } = paneIds(params)
  refuseMismatchedBodyId("Pane", payload, paneId)
  requireWorkspace(await findWorkspace(services, workspaceId), workspaceId)

  const pane = await run(services.db.upsertWorkspacePane(workspaceId, { ...payload, id: paneId }))
  await publishPaneUpdated(route, pane)
  writeJson(response, 200, pane)
  return true
}

const updatePane = async (route: RouteContext, params: RouteParams): Promise<boolean> => {
  const { services, request, response } = route
  const payload = await readSchema(request, UpdateWorkspacePaneRequestSchema)
  const ids = paneIds(params)
  const panes = await run(services.db.listWorkspacePanes)
  if (!hasPane(panes, ids)) throw new HttpFailure(404, `Workspace pane not found: ${ids.paneId}`)

  const pane = await run(services.db.updateWorkspacePane(ids.workspaceId, ids.paneId, payload))
  await publishPaneUpdated(route, pane)
  writeJson(response, 200, pane)
  return true
}

const paneToClose = (
  request: IncomingMessage,
  closeRoute: RouteParams | undefined,
  paneRoute: RouteParams | undefined
): RouteParams | undefined => {
  if (closeRoute !== undefined && request.method === "POST") return closeRoute
  if (paneRoute !== undefined && request.method === "DELETE") return paneRoute
  return undefined
}

const paneIds = (params: RouteParams): PaneIds => ({
  workspaceId: routeParam(params, "workspaceId"),
  paneId: routeParam(params, "paneId")
})

const promotedWorkspace = (workspaces: ReadonlyArray<Workspace>, ids: PaneIds): Workspace => {
  const workspace = workspaceWithId(workspaces, ids.workspaceId)
  if (workspace === undefined) throw new HttpFailure(404, "Workspace not found")
  return workspace
}

const requirePromotedPane = (panes: ReadonlyArray<WorkspacePane>, ids: PaneIds): void => {
  if (paneIn(panes, ids) === undefined) throw new HttpFailure(404, "Workspace pane not found")
}

const paneIn = (panes: ReadonlyArray<WorkspacePane>, ids: PaneIds): WorkspacePane | undefined =>
  panes.find((candidate) => isPane(candidate, ids))

const hasPane = (panes: ReadonlyArray<WorkspacePane>, ids: PaneIds): boolean =>
  panes.some((candidate) => isPane(candidate, ids))

const isPane = (candidate: WorkspacePane, ids: PaneIds): boolean =>
  sameId(candidate.id, ids.paneId) && sameId(candidate.workspaceId, ids.workspaceId)

const refuseCrossProjectChat = (
  workspace: Workspace,
  payload: PromoteWorkspacePaneToChatRequest
): void => {
  if (inOtherProject(workspace, payload)) {
    throw new HttpFailure(409, "Chat and workspace must belong to the same project")
  }
}

const inOtherProject = (
  workspace: Workspace,
  payload: PromoteWorkspacePaneToChatRequest
): boolean => workspace.projectId.toLowerCase() !== payload.session.projectId.toLowerCase()

const ensureChat = (route: RouteContext, chat: CreateSessionRequest): Promise<EnsuredChat> =>
  createSessionIfMissing(
    route.services,
    route.fanout,
    route.routeState,
    route.config,
    { ...chat, workspaceId: undefined },
    false
  )

const promotePane = (
  { services }: RouteContext,
  ids: PaneIds,
  session: SessionSummary,
  payload: PromoteWorkspacePaneToChatRequest
): Promise<WorkspacePane> =>
  run(
    services.db.promoteWorkspacePaneToSession(
      ids.workspaceId,
      ids.paneId,
      session.id,
      promotedTitle(payload, session)
    )
  )

const promotedTitle = (
  payload: PromoteWorkspacePaneToChatRequest,
  session: SessionSummary
): string => payload.title ?? (session.title || "New Chat")

const chatEventKind = (created: boolean): EventEnvelope["kind"] =>
  created ? "session.created" : "session.updated"

const publishSession = (
  { services, fanout }: RouteContext,
  kind: EventEnvelope["kind"],
  session: SessionSummary
): Promise<EventEnvelope> => appendAndPublish(services.db, fanout, kind, session.id, session)

const publishPaneUpdated = (
  { services, fanout }: RouteContext,
  pane: WorkspacePane
): Promise<EventEnvelope> =>
  appendAndPublish(services.db, fanout, "workspace.pane.updated", pane.id, pane)

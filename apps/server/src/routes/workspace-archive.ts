import { ArchiveWorkspaceRequest, type ArchivedWorkspace } from "@codevisor/api"

import { archiveWorkspaceNow } from "../archive-jobs.js"
import { matchRoute, readSchema, writeJson } from "../server-context.js"
import { assertNotOwnedByBot } from "./bot-guards.js"
import type { RouteContext } from "./route-context.js"
import { archiveContextOf, callerOf, deferWorkspaceArchive, isInside } from "./self-archive.js"
import { findWorkspace, requireWorkspace } from "./workspace-lookups.js"

export const routeWorkspaceArchive = (route: RouteContext): Promise<boolean> | undefined => {
  const workspaceId = matchRoute(route.url.pathname, "/v1/workspaces/:id/archive")
  if (workspaceId === undefined || route.request.method !== "POST") return undefined
  return archiveWorkspace(route, workspaceId)
}

const archiveWorkspace = async (route: RouteContext, workspaceId: string): Promise<boolean> => {
  const { callerAgentId } = await readSchema(route.request, ArchiveWorkspaceRequest)
  const workspace = requireWorkspace(await findWorkspace(route.services, workspaceId), workspaceId)
  const caller = await callerOf(route, callerAgentId)
  await assertNotOwnedByBot(route.services, { workspaceId: workspace.id }, "archive this workspace")

  if (isInside(caller, workspace)) {
    const later = await deferWorkspaceArchive(route, caller, workspace)
    return respond(route, { workspaceId: workspace.id, ...later })
  }
  await archiveWorkspaceNow(archiveContextOf(route), workspace)
  return respond(route, { workspaceId: workspace.id, archived: true })
}

const respond = (route: RouteContext, body: ArchivedWorkspace): boolean => {
  writeJson(route.response, 200, body)
  return true
}

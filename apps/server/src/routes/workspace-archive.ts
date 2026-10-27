import { ArchiveWorkspaceRequest, type ArchivedWorkspace, type Workspace } from "@codevisor/api"

import { archiveWorkspaceAndWait } from "../archive-jobs.js"
import {
  appendAndPublish,
  HttpFailure,
  matchRoute,
  readSchema,
  run,
  writeJson
} from "../server-context.js"
import { captureWorkspaceRuntime } from "../server-workspace-effects.js"
import { assertNotOwnedByBot } from "./bot-guards.js"
import type { RouteContext } from "./route-context.js"
import { findSession } from "./session-workspace.js"
import { findWorkspace, requireWorkspace, sameId } from "./workspace-lookups.js"

export const routeWorkspaceArchive = (route: RouteContext): Promise<boolean> | undefined => {
  const workspaceId = matchRoute(route.url.pathname, "/v1/workspaces/:id/archive")
  if (workspaceId === undefined || route.request.method !== "POST") return undefined
  return archiveWorkspace(route, workspaceId)
}

const archiveWorkspace = async (route: RouteContext, workspaceId: string): Promise<boolean> => {
  const { callerAgentId } = await readSchema(route.request, ArchiveWorkspaceRequest)
  const workspace = requireWorkspace(await findWorkspace(route.services, workspaceId), workspaceId)
  await refuseCallerWorkspace(route, workspace, callerAgentId)
  await assertNotOwnedByBot(route.services, { workspaceId: workspace.id }, "archive this workspace")

  await archiveAndWait(route, workspace)
  const archived: ArchivedWorkspace = { workspaceId: workspace.id, archived: true }
  writeJson(route.response, 200, archived)
  return true
}

const refuseCallerWorkspace = async (
  { services }: RouteContext,
  workspace: Workspace,
  callerAgentId: string | undefined
): Promise<void> => {
  if (callerAgentId === undefined) return
  const caller = await findSession(services.db, callerAgentId)
  if (caller === undefined) throw new HttpFailure(422, `Unknown caller: ${callerAgentId}`)
  if (caller.workspaceId !== undefined && sameId(caller.workspaceId, workspace.id)) {
    throw new HttpFailure(
      422,
      `Workspace ${workspace.id} is your own: you can't archive it. To remove a helper's tab from it, call agents.close({ agentId })`
    )
  }
}

const archiveAndWait = async (
  { services, fanout, config, routeState }: RouteContext,
  workspace: Workspace
): Promise<void> => {
  const archived = await run(services.db.updateWorkspace(workspace.id, { isArchived: true }))
  await appendAndPublish(services.db, fanout, "workspace.updated", archived.id, archived)
  const runtime = await captureWorkspaceRuntime(services, routeState, archived)
  await archiveWorkspaceAndWait(services, fanout, config, archived, runtime)
}

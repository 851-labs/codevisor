import type { Workspace, WorkspaceSize } from "@codevisor/api"

import { directorySize } from "../infra/directory-size.js"
import { existingDirectory, matchRouteParams, writeJson } from "../server-context.js"
import type { RouteContext } from "./route-context.js"
import { routeParam } from "./route-params.js"
import { findWorkspace, requireWorkspace } from "./workspace-lookups.js"

export const routeWorkspaceSize = (route: RouteContext): Promise<boolean> | undefined => {
  if (route.request.method !== "GET") return undefined
  const params = matchRouteParams(route.url.pathname, "/v1/workspaces/:workspaceId/size")
  if (params === undefined) return undefined
  return readWorkspaceSize(route, routeParam(params, "workspaceId"))
}

const readWorkspaceSize = async (
  { services, response }: RouteContext,
  workspaceId: string
): Promise<boolean> => {
  const workspace = requireWorkspace(await findWorkspace(services, workspaceId), workspaceId)
  writeJson(response, 200, await workspaceSize(workspace))
  return true
}

const workspaceSize = async (workspace: Workspace): Promise<WorkspaceSize> => {
  const directory = checkoutDirectory(workspace)
  if (directory === undefined) return {}

  const bytes = await directorySize(directory)
  if (bytes === undefined) return {}
  return { bytes }
}

const checkoutDirectory = (workspace: Workspace): string | undefined => {
  if (workspace.isArchived) return undefined
  return existingDirectory(workspace.rootDirectory ?? null)
}

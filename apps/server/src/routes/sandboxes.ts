import { ClaimSandboxWorkspaceRequest, CreateSandboxRequest } from "@codevisor/api"

import type { SandboxCatalogDeps } from "../infra/sandbox-catalog.js"
import type { SandboxSetupPublisher } from "../infra/sandbox-setup-log.js"
import type { Sandboxes } from "../infra/sandboxes.js"
import { appendAndPublish, HttpFailure, readSchema, writeJson } from "../server-context.js"
import { isRoute, methodRouteId, type RouteContext } from "./route-context.js"
import { routeSandboxSettings } from "./sandbox-settings.js"

export interface SandboxesService {
  readonly sandboxes: Sandboxes
  readonly catalog: SandboxCatalogDeps
}

export const routeSandboxes = async (route: RouteContext): Promise<boolean> => {
  if (!route.url.pathname.startsWith("/v1/sandbox")) return false
  const service = route.services.sandboxes
  if (service === undefined) throw new HttpFailure(501, "Sandboxes are unavailable here")

  if (await routeSandboxSettings(route, service.catalog)) return true
  return dispatchSandboxes(route, service.sandboxes)
}

const dispatchSandboxes = async (route: RouteContext, sandboxes: Sandboxes): Promise<boolean> => {
  const { request, response, url } = route
  if (isRoute(url, request, "/v1/sandboxes", "GET")) {
    writeJson(response, 200, await sandboxes.list())
    return true
  }
  if (isRoute(url, request, "/v1/sandboxes", "POST")) {
    const body = await readSchema(request, CreateSandboxRequest)
    writeJson(response, 202, await sandboxes.create(body, setupPublisher(route)))
    return true
  }
  const destroyId = methodRouteId(route, "DELETE", "/v1/sandboxes/:id")
  if (destroyId !== undefined) {
    await sandboxes.destroy(destroyId)
    writeJson(response, 200, { destroyed: destroyId })
    return true
  }
  const claimId = methodRouteId(route, "POST", "/v1/sandboxes/:id/workspace")
  if (claimId === undefined) return false

  const { workspaceId } = await readSchema(request, ClaimSandboxWorkspaceRequest)
  writeJson(response, 200, await sandboxes.claimWorkspace(claimId, workspaceId))
  return true
}

const setupPublisher =
  (route: RouteContext): SandboxSetupPublisher =>
  async (log) => {
    await appendAndPublish(route.services.db, route.fanout, "sandbox.setup", log.machineId, log)
  }

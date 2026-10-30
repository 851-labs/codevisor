import {
  ClaimSandboxWorkspaceRequest,
  CreateSandboxRequest,
  DEFAULT_SANDBOX_WAIT_TIMEOUT_MS,
  MAX_SANDBOX_WAIT_TIMEOUT_MS,
  WaitForSandboxRequest
} from "@codevisor/api"

import type { SandboxCatalogDeps } from "../infra/sandbox-catalog.js"
import type { SandboxEventPublisher } from "../infra/sandbox-local-workspaces.js"
import type { SandboxSetupPublisher } from "../infra/sandbox-setup-log.js"
import type { Sandboxes } from "../infra/sandboxes.js"
import { appendAndPublish, HttpFailure, readSchema, writeJson } from "../server-context.js"
import { isRoute, methodRouteId, type RouteContext } from "./route-context.js"
import { routeSandboxSettings } from "./sandbox-settings.js"

export interface SandboxesService {
  readonly sandboxes: Sandboxes
  readonly catalog: SandboxCatalogDeps
  readonly bindEvents?: (publish: SandboxEventPublisher) => void
}

export const routeSandboxes = async (route: RouteContext): Promise<boolean> => {
  if (!route.url.pathname.startsWith("/v1/sandbox")) return false
  const service = route.services.sandboxes
  if (service === undefined) throw new HttpFailure(501, "Sandboxes are unavailable here")

  if (await routeSandboxSettings(route, service.catalog)) return true
  return dispatchSandboxes(route, service.sandboxes)
}

export const bindSandboxEvents = ({ services, fanout }: RouteContext): void => {
  services.sandboxes?.bindEvents?.((kind, id, payload) =>
    appendAndPublish(services.db, fanout, kind, id, payload)
  )
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
  if (await readSandbox(route, sandboxes)) return true
  const waitId = methodRouteId(route, "POST", "/v1/sandboxes/:id/wait")
  if (waitId !== undefined) {
    const { timeoutMs } = await readSchema(request, WaitForSandboxRequest)
    writeJson(response, 200, await sandboxes.wait(waitId, waitTimeout(timeoutMs)))
    return true
  }
  const wakeId = methodRouteId(route, "POST", "/v1/sandboxes/:id/wake")
  if (wakeId !== undefined) {
    writeJson(response, 202, await sandboxes.wake(wakeId))
    return true
  }
  const retryId = methodRouteId(route, "POST", "/v1/sandboxes/:id/retry")
  if (retryId !== undefined) {
    writeJson(response, 202, await sandboxes.retry(retryId, setupPublisher(route)))
    return true
  }
  const claimId = methodRouteId(route, "POST", "/v1/sandboxes/:id/workspace")
  if (claimId === undefined) return false

  const { workspaceId } = await readSchema(request, ClaimSandboxWorkspaceRequest)
  writeJson(response, 200, await sandboxes.claimWorkspace(claimId, workspaceId))
  return true
}

const readSandbox = async (route: RouteContext, sandboxes: Sandboxes): Promise<boolean> => {
  const getId = methodRouteId(route, "GET", "/v1/sandboxes/:id")
  if (getId !== undefined) {
    writeJson(route.response, 200, await sandboxes.get(getId))
    return true
  }
  const logId = methodRouteId(route, "GET", "/v1/sandboxes/:id/log")
  if (logId === undefined) return false

  writeJson(route.response, 200, { lines: await sandboxes.log(logId, lastLines(route.url)) })
  return true
}

const waitTimeout = (timeoutMs: number | undefined): number =>
  Math.min(Math.max(timeoutMs ?? DEFAULT_SANDBOX_WAIT_TIMEOUT_MS, 0), MAX_SANDBOX_WAIT_TIMEOUT_MS)

const lastLines = (url: URL): number | undefined => {
  const raw = url.searchParams.get("last")
  if (raw === null || raw === "") return undefined
  const last = Number(raw)
  if (!Number.isSafeInteger(last) || last < 1) {
    throw new HttpFailure(400, "last must be a positive integer")
  }
  return last
}

export const setupPublisher =
  (route: RouteContext): SandboxSetupPublisher =>
  async (log) => {
    await appendAndPublish(route.services.db, route.fanout, "sandbox.setup", log.machineId, log)
  }

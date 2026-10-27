import {
  ClaimSandboxWorkspaceRequest,
  CreateSandboxRequest,
  SandboxProjectOptions,
  SaveSandboxCredentialsRequest,
  type SandboxProjectOptions as ProjectOptions,
  type SandboxProviderSummary
} from "@codevisor/api"
import {
  decodeProviderOptions,
  SANDBOX_PROVIDER_CATALOG,
  SANDBOX_PROVIDER_IDS,
  isSandboxProviderId,
  type SandboxProviderId
} from "@codevisor/sandboxes"

import {
  SANDBOX_CREDENTIAL_KEYS,
  type SandboxCredentialStore
} from "../infra/sandbox-credentials.js"
import type { SandboxSetupPublisher } from "../infra/sandbox-setup-log.js"
import type { SandboxRecordStore } from "../infra/sandbox-store.js"
import { asBadRequest, type Sandboxes } from "../infra/sandboxes.js"
import { appendAndPublish, HttpFailure, readSchema, writeJson } from "../server-context.js"
import { isRoute, methodRouteId, type RouteContext } from "./route-context.js"

export interface SandboxesService {
  readonly machines: Sandboxes
  readonly credentials: SandboxCredentialStore
  readonly records: SandboxRecordStore
}

export const routeSandboxes = async (route: RouteContext): Promise<boolean> => {
  if (!route.url.pathname.startsWith("/v1/sandbox") && !isProjectOptionsPath(route.url)) {
    return false
  }
  const service = route.services.sandboxes
  if (service === undefined) throw new HttpFailure(501, "Sandboxes are unavailable here")

  return dispatch(route, service)
}

const dispatch = async (route: RouteContext, service: SandboxesService): Promise<boolean> => {
  const { request, response, url } = route
  if (isRoute(url, request, "/v1/sandbox-providers", "GET")) {
    writeJson(response, 200, { providers: await providerSummaries(service) })
    return true
  }
  const credentialsFor = methodRouteId(route, "PUT", "/v1/sandbox-providers/:id/credentials")
  if (credentialsFor !== undefined)
    return saveCredentials(route, service, providerId(credentialsFor))

  const clearFor = methodRouteId(route, "DELETE", "/v1/sandbox-providers/:id/credentials")
  if (clearFor !== undefined) {
    await service.credentials.clear(providerId(clearFor))
    response.writeHead(204).end()
    return true
  }
  return dispatchMachines(route, service)
}

const dispatchMachines = async (
  route: RouteContext,
  service: SandboxesService
): Promise<boolean> => {
  const { request, response, url } = route
  if (isRoute(url, request, "/v1/sandboxes", "GET")) {
    writeJson(response, 200, await service.machines.list())
    return true
  }
  if (isRoute(url, request, "/v1/sandboxes", "POST")) {
    const body = await readSchema(request, CreateSandboxRequest)
    writeJson(response, 202, await service.machines.create(body, setupPublisher(route)))
    return true
  }
  const destroyId = methodRouteId(route, "DELETE", "/v1/sandboxes/:id")
  if (destroyId !== undefined) {
    await service.machines.destroy(destroyId)
    writeJson(response, 200, { destroyed: destroyId })
    return true
  }
  const claimId = methodRouteId(route, "POST", "/v1/sandboxes/:id/workspace")
  if (claimId !== undefined) {
    const { workspaceId } = await readSchema(request, ClaimSandboxWorkspaceRequest)
    writeJson(response, 200, await service.machines.claimWorkspace(claimId, workspaceId))
    return true
  }
  return dispatchProjectOptions(route, service)
}

const dispatchProjectOptions = async (
  route: RouteContext,
  service: SandboxesService
): Promise<boolean> => {
  const readFor = methodRouteId(route, "GET", "/v1/projects/:id/sandbox-options")
  if (readFor !== undefined) {
    writeJson(route.response, 200, {
      projectId: readFor,
      options: await service.records.projectOptions(readFor)
    })
    return true
  }
  const writeFor = methodRouteId(route, "PUT", "/v1/projects/:id/sandbox-options")
  if (writeFor === undefined) return false

  const options = validatedOptions(await readSchema(route.request, SandboxProjectOptions))
  await service.records.setProjectOptions(writeFor, options)
  writeJson(route.response, 200, { projectId: writeFor, options })
  return true
}

const saveCredentials = async (
  route: RouteContext,
  service: SandboxesService,
  provider: SandboxProviderId
): Promise<boolean> => {
  const body = await readSchema(route.request, SaveSandboxCredentialsRequest)
  await service.credentials.save(provider, body.values)
  route.response.writeHead(204).end()
  return true
}

const providerSummaries = async (
  service: SandboxesService
): Promise<ReadonlyArray<SandboxProviderSummary>> => {
  const configured = new Set(await service.machines.configuredProviders())
  return SANDBOX_PROVIDER_IDS.map((id) => ({
    id,
    displayName: SANDBOX_PROVIDER_CATALOG[id].displayName,
    configured: configured.has(id),
    credentialKeys: SANDBOX_CREDENTIAL_KEYS[id],
    defaults: defaultsFor(id)
  }))
}

const defaultsFor = (id: SandboxProviderId): Readonly<Record<string, unknown>> =>
  decodeProviderOptions(SANDBOX_PROVIDER_CATALOG[id], {})

const validatedOptions = (options: ProjectOptions): ProjectOptions => {
  for (const [id, overrides] of Object.entries(options)) {
    asBadRequest(() => decodeProviderOptions(SANDBOX_PROVIDER_CATALOG[providerId(id)], overrides))
  }
  return options
}

const providerId = (value: string): SandboxProviderId => {
  if (!isSandboxProviderId(value)) throw new HttpFailure(404, `No sandbox provider ${value}`)
  return value
}

const isProjectOptionsPath = (url: URL): boolean =>
  url.pathname.startsWith("/v1/projects/") && url.pathname.endsWith("/sandbox-options")

const setupPublisher =
  (route: RouteContext): SandboxSetupPublisher =>
  async (log) => {
    await appendAndPublish(route.services.db, route.fanout, "sandbox.setup", log.machineId, log)
  }

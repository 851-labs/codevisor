import {
  ClaimEphemeralWorkspaceRequest,
  CreateEphemeralMachineRequest,
  EphemeralProjectOptions,
  SaveEphemeralCredentialsRequest,
  type EphemeralProjectOptions as ProjectOptions,
  type EphemeralProviderSummary
} from "@codevisor/api"
import {
  decodeProviderOptions,
  EPHEMERAL_PROVIDER_CATALOG,
  EPHEMERAL_PROVIDER_IDS,
  isEphemeralProviderId,
  type EphemeralProviderId
} from "@codevisor/ephemeral-machines"

import {
  EPHEMERAL_CREDENTIAL_KEYS,
  type EphemeralCredentialStore
} from "../infra/ephemeral-credentials.js"
import { asBadRequest, type EphemeralMachines } from "../infra/ephemeral-machines.js"
import type { EphemeralSetupPublisher } from "../infra/ephemeral-setup-log.js"
import type { EphemeralRecordStore } from "../infra/ephemeral-store.js"
import { appendAndPublish, HttpFailure, readSchema, writeJson } from "../server-context.js"
import { isRoute, methodRouteId, type RouteContext } from "./route-context.js"

export interface EphemeralMachinesService {
  readonly machines: EphemeralMachines
  readonly credentials: EphemeralCredentialStore
  readonly records: EphemeralRecordStore
}

export const routeEphemeralMachines = async (route: RouteContext): Promise<boolean> => {
  if (!route.url.pathname.startsWith("/v1/ephemeral-") && !isProjectOptionsPath(route.url)) {
    return false
  }
  const service = route.services.ephemeralMachines
  if (service === undefined) throw new HttpFailure(501, "Ephemeral machines are unavailable here")

  return dispatch(route, service)
}

const dispatch = async (
  route: RouteContext,
  service: EphemeralMachinesService
): Promise<boolean> => {
  const { request, response, url } = route
  if (isRoute(url, request, "/v1/ephemeral-providers", "GET")) {
    writeJson(response, 200, { providers: await providerSummaries(service) })
    return true
  }
  const credentialsFor = methodRouteId(route, "PUT", "/v1/ephemeral-providers/:id/credentials")
  if (credentialsFor !== undefined)
    return saveCredentials(route, service, providerId(credentialsFor))

  const clearFor = methodRouteId(route, "DELETE", "/v1/ephemeral-providers/:id/credentials")
  if (clearFor !== undefined) {
    await service.credentials.clear(providerId(clearFor))
    response.writeHead(204).end()
    return true
  }
  return dispatchMachines(route, service)
}

const dispatchMachines = async (
  route: RouteContext,
  service: EphemeralMachinesService
): Promise<boolean> => {
  const { request, response, url } = route
  if (isRoute(url, request, "/v1/ephemeral-machines", "GET")) {
    writeJson(response, 200, await service.machines.list())
    return true
  }
  if (isRoute(url, request, "/v1/ephemeral-machines", "POST")) {
    const body = await readSchema(request, CreateEphemeralMachineRequest)
    writeJson(response, 202, await service.machines.create(body, setupPublisher(route)))
    return true
  }
  const destroyId = methodRouteId(route, "DELETE", "/v1/ephemeral-machines/:id")
  if (destroyId !== undefined) {
    await service.machines.destroy(destroyId)
    writeJson(response, 200, { destroyed: destroyId })
    return true
  }
  const claimId = methodRouteId(route, "POST", "/v1/ephemeral-machines/:id/workspace")
  if (claimId !== undefined) {
    const { workspaceId } = await readSchema(request, ClaimEphemeralWorkspaceRequest)
    writeJson(response, 200, await service.machines.claimWorkspace(claimId, workspaceId))
    return true
  }
  return dispatchProjectOptions(route, service)
}

const dispatchProjectOptions = async (
  route: RouteContext,
  service: EphemeralMachinesService
): Promise<boolean> => {
  const readFor = methodRouteId(route, "GET", "/v1/projects/:id/ephemeral-options")
  if (readFor !== undefined) {
    writeJson(route.response, 200, {
      projectId: readFor,
      options: await service.records.projectOptions(readFor)
    })
    return true
  }
  const writeFor = methodRouteId(route, "PUT", "/v1/projects/:id/ephemeral-options")
  if (writeFor === undefined) return false

  const options = validatedOptions(await readSchema(route.request, EphemeralProjectOptions))
  await service.records.setProjectOptions(writeFor, options)
  writeJson(route.response, 200, { projectId: writeFor, options })
  return true
}

const saveCredentials = async (
  route: RouteContext,
  service: EphemeralMachinesService,
  provider: EphemeralProviderId
): Promise<boolean> => {
  const body = await readSchema(route.request, SaveEphemeralCredentialsRequest)
  await service.credentials.save(provider, body.values)
  route.response.writeHead(204).end()
  return true
}

const providerSummaries = async (
  service: EphemeralMachinesService
): Promise<ReadonlyArray<EphemeralProviderSummary>> => {
  const configured = new Set(await service.machines.configuredProviders())
  return EPHEMERAL_PROVIDER_IDS.map((id) => ({
    id,
    displayName: EPHEMERAL_PROVIDER_CATALOG[id].displayName,
    configured: configured.has(id),
    credentialKeys: EPHEMERAL_CREDENTIAL_KEYS[id],
    defaults: defaultsFor(id)
  }))
}

const defaultsFor = (id: EphemeralProviderId): Readonly<Record<string, unknown>> =>
  decodeProviderOptions(EPHEMERAL_PROVIDER_CATALOG[id], {})

const validatedOptions = (options: ProjectOptions): ProjectOptions => {
  for (const [id, overrides] of Object.entries(options)) {
    asBadRequest(() => decodeProviderOptions(EPHEMERAL_PROVIDER_CATALOG[providerId(id)], overrides))
  }
  return options
}

const providerId = (value: string): EphemeralProviderId => {
  if (!isEphemeralProviderId(value)) throw new HttpFailure(404, `No ephemeral provider ${value}`)
  return value
}

const isProjectOptionsPath = (url: URL): boolean =>
  url.pathname.startsWith("/v1/projects/") && url.pathname.endsWith("/ephemeral-options")

const setupPublisher =
  (route: RouteContext): EphemeralSetupPublisher =>
  async (log) => {
    await appendAndPublish(route.services.db, route.fanout, "ephemeral.setup", log.machineId, log)
  }

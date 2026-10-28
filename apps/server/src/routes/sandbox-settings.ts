import { SaveSandboxAccountRequest, SaveSandboxProfileRequest } from "@codevisor/api"

import {
  createAccount,
  createProfile,
  deleteAccount,
  deleteProfile,
  hostCapabilities,
  hostMaximums,
  listAccounts,
  profileAvailability,
  providerInfos,
  updateAccount,
  updateProfile,
  type SandboxCatalogDeps
} from "../infra/sandbox-catalog.js"
import type { SandboxSettingsChange } from "../infra/sandbox-settings.js"
import { appendAndPublish, readSchema, swallowError, writeJson } from "../server-context.js"
import { isRoute, methodRouteId, type RouteContext } from "./route-context.js"

export const routeSandboxSettings = async (
  route: RouteContext,
  catalog: SandboxCatalogDeps
): Promise<boolean> => {
  const { request, response, url } = route
  if (isRoute(url, request, "/v1/sandbox-providers", "GET")) {
    const { adapters } = catalog
    writeJson(response, 200, {
      providers: providerInfos(adapters),
      capabilities: hostCapabilities(adapters),
      maximums: hostMaximums(adapters)
    })
    return true
  }
  if (isRoute(url, request, "/v1/sandbox-profiles/availability", "GET")) {
    writeJson(response, 200, { profiles: await profileAvailability(catalog) })
    return true
  }
  if (await routeAccounts(route, catalog)) return true
  return routeProfiles(route, catalog)
}

const routeAccounts = async (
  route: RouteContext,
  catalog: SandboxCatalogDeps
): Promise<boolean> => {
  const { request, response, url } = route
  if (isRoute(url, request, "/v1/sandbox-accounts", "GET")) {
    writeJson(response, 200, { accounts: await listAccounts(catalog) })
    return true
  }
  if (isRoute(url, request, "/v1/sandbox-accounts", "POST")) {
    const saved = await createAccount(catalog, await readSchema(request, SaveSandboxAccountRequest))
    return respond(route, 201, saved.account, saved.change)
  }
  const updateId = methodRouteId(route, "PUT", "/v1/sandbox-accounts/:id")
  if (updateId !== undefined) {
    const body = await readSchema(request, SaveSandboxAccountRequest)
    const saved = await updateAccount(catalog, updateId, body)
    return respond(route, 200, saved.account, saved.change)
  }
  const deleteId = methodRouteId(route, "DELETE", "/v1/sandbox-accounts/:id")
  if (deleteId === undefined) return false

  return respond(route, 204, undefined, await deleteAccount(catalog, deleteId))
}

const routeProfiles = async (
  route: RouteContext,
  catalog: SandboxCatalogDeps
): Promise<boolean> => {
  const { request, response, url } = route
  if (isRoute(url, request, "/v1/sandbox-profiles", "GET")) {
    writeJson(response, 200, { profiles: await catalog.settings.profiles() })
    return true
  }
  if (isRoute(url, request, "/v1/sandbox-profiles", "POST")) {
    const saved = await createProfile(catalog, await readSchema(request, SaveSandboxProfileRequest))
    return respond(route, 201, saved.profile, saved.change)
  }
  const updateId = methodRouteId(route, "PUT", "/v1/sandbox-profiles/:id")
  if (updateId !== undefined) {
    const body = await readSchema(request, SaveSandboxProfileRequest)
    const saved = await updateProfile(catalog, updateId, body)
    return respond(route, 200, saved.profile, saved.change)
  }
  const deleteId = methodRouteId(route, "DELETE", "/v1/sandbox-profiles/:id")
  if (deleteId === undefined) return false

  return respond(route, 204, undefined, await deleteProfile(catalog, deleteId))
}

const respond = (
  route: RouteContext,
  status: number,
  body: unknown,
  change: SandboxSettingsChange
): boolean => {
  publishChange(route, change)
  if (body === undefined) route.response.writeHead(status).end()
  else writeJson(route.response, status, body)
  return true
}

const publishChange = (route: RouteContext, change: SandboxSettingsChange): void => {
  void appendAndPublish(route.services.db, route.fanout, "sync.changed", change.namespace, {
    namespace: change.namespace,
    entries: change.entries
  }).catch(swallowError)
}

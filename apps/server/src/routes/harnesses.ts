import type { IncomingMessage, ServerResponse } from "node:http"

import { UpdateHarnessRequest as UpdateHarnessRequestSchema } from "@codevisor/api"

import { HARNESSES_SYNC_NAMESPACE, setHarnessPreference } from "../infra/harness-preferences.js"
import {
  appendAndPublish,
  HttpFailure,
  matchRoute,
  readJson,
  readSchema,
  run,
  swallowError,
  writeJson
} from "../server-context.js"
import type {
  CodevisorServerConfig,
  CodevisorServerServices,
  EventFanout
} from "../server-context.js"
import { routeHarnessAuth } from "./harness-auth-routes.js"
import { discoverHarnesses } from "./harness-discovery.js"
import { conflictFrom } from "./harness-errors.js"

export {
  discoverCapabilities,
  discoverHarnesses,
  discoverHarnessesFromStoredAuthState
} from "./harness-discovery.js"

export const routeHarnesses = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (await routeHarnessAuth(services, request, response, url)) {
    return true
  }
  if (request.method === "GET" && url.pathname === "/v1/harnesses")
    return listHarnesses(services, response, url)
  if (request.method === "POST" && url.pathname === "/v1/harnesses/rescan")
    return rescanHarnesses(services, response)
  if (request.method === "POST" && url.pathname === "/v1/harnesses/check-updates")
    return checkHarnessUpdates(services, request, response)
  const installHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/install")
  if (installHarnessId !== undefined && request.method === "POST")
    return installHarness(services, config, fanout, request, response, installHarnessId)
  const bundledAppHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/bundled-app")
  if (bundledAppHarnessId !== undefined && request.method === "GET")
    return getBundledHarnessApp(services, response, bundledAppHarnessId)
  const bundledAppUpdateHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/bundled-app/update")
  if (bundledAppUpdateHarnessId !== undefined && request.method === "POST")
    return updateBundledHarnessApp(services, response, bundledAppUpdateHarnessId)
  const pendingApplyHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/update/pending/apply")
  if (pendingApplyHarnessId !== undefined && request.method === "POST")
    return applyPendingHarnessUpdate(services, response, pendingApplyHarnessId)
  const pendingCancelHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/update/pending")
  if (pendingCancelHarnessId !== undefined && request.method === "DELETE")
    return cancelPendingHarnessUpdate(services, response, pendingCancelHarnessId)
  const updateHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/update")
  if (updateHarnessId !== undefined && request.method === "POST")
    return updateHarness(services, response, updateHarnessId)
  const agentSessionsHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/agent-sessions")
  if (agentSessionsHarnessId !== undefined && request.method === "GET")
    return listHarnessAgentSessions(services, response, agentSessionsHarnessId)
  const harnessId = matchRoute(url.pathname, "/v1/harnesses/:id")
  if (harnessId !== undefined && request.method === "PATCH")
    return updateHarnessPreference(services, config, fanout, request, response, harnessId)
  return false
}

/// Every desired-state mutation on this machine writes the fleet catalog
/// (the one document Settings renders) and publishes the change so open
/// clients see the row move without waiting for a sync sweep.
const writeHarnessCatalog = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  harnessId: string,
  preference: { readonly enabled: boolean; readonly installed: boolean }
): Promise<void> => {
  const definition = services.agents.catalog.find((item) => item.id === harnessId)
  /* v8 ignore next -- PATCH answers 404 and the lifecycle manager 409 for unknown ids before this runs. */
  if (definition === undefined) throw new HttpFailure(404, "Harness not found")
  // Every write stamps a fresh timestamp, so the merge always reports a
  // change worth publishing.
  const changed = await setHarnessPreference(
    services.db,
    config.id,
    { id: definition.id, name: definition.name, symbolName: definition.symbolName },
    preference
  )
  void appendAndPublish(services.db, fanout, "sync.changed", HARNESSES_SYNC_NAMESPACE, {
    namespace: HARNESSES_SYNC_NAMESPACE,
    entries: changed
  }).catch(swallowError)
}

const listHarnesses = async (
  services: CodevisorServerServices,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const includeLifecycle = url.searchParams.get("include") === "lifecycle"
  writeJson(response, 200, await discoverHarnesses(services, false, undefined, includeLifecycle))
  return true
}

// Re-resolves the runtime's PATH (login-shell probe) before re-detecting,
// so a CLI installed after server start is found without a restart.
const rescanHarnesses = async (
  services: CodevisorServerServices,
  response: ServerResponse
): Promise<boolean> => {
  await run(services.agents.refreshEnvironment)
  writeJson(response, 200, await discoverHarnesses(services, true, undefined, true))
  return true
}

// Forced latest-version check, then the refreshed list (blocking rescan
// pattern — checks are cheap fetches). An optional `harnessIds` body limits
// the check to the harnesses the client lists; without it, every
// installed harness is checked.
const checkHarnessUpdates = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse
): Promise<boolean> => {
  if (services.lifecycle === undefined)
    throw new HttpFailure(501, "Harness update checks unavailable")
  const body = (await readJson(request)) as { readonly harnessIds?: unknown }
  const harnessIds = Array.isArray(body.harnessIds)
    ? body.harnessIds.filter((id): id is string => typeof id === "string")
    : undefined
  await services.lifecycle.checkForUpdates(true, harnessIds)
  writeJson(response, 200, await discoverHarnesses(services, false, undefined, true))
  return true
}

// One-click install: 202-ack, work runs in the background, progress via
// harness.lifecycle.updated events + the attachable output terminal.
const installHarness = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  request: IncomingMessage,
  response: ServerResponse,
  installHarnessId: string
): Promise<boolean> => {
  if (services.lifecycle === undefined) throw new HttpFailure(501, "Harness install unavailable")
  const body = (await readJson(request)) as { readonly methodId?: string }
  const methodId = typeof body.methodId === "string" ? body.methodId : undefined
  try {
    const { terminalId } = await services.lifecycle.beginInstall(installHarnessId, methodId)
    await writeHarnessCatalog(services, config, fanout, installHarnessId, {
      installed: true,
      enabled: true
    })
    writeJson(response, 202, { accepted: true, terminalId })
  } catch (cause) {
    throw conflictFrom(cause)
  }
  return true
}

// Dual-install: the bundled desktop app's version/update state, computed
// on demand (detail sheet), and its explicit update action.
const getBundledHarnessApp = async (
  services: CodevisorServerServices,
  response: ServerResponse,
  bundledAppHarnessId: string
): Promise<boolean> => {
  if (services.lifecycle === undefined)
    throw new HttpFailure(501, "Harness update checks unavailable")
  const info = await services.lifecycle.bundledAppInfo(bundledAppHarnessId).catch(swallowError)
  if (info === undefined) throw new HttpFailure(404, "No bundled desktop app")
  writeJson(response, 200, info)
  return true
}

const updateBundledHarnessApp = async (
  services: CodevisorServerServices,
  response: ServerResponse,
  bundledAppUpdateHarnessId: string
): Promise<boolean> => {
  if (services.lifecycle === undefined)
    throw new HttpFailure(501, "Harness update checks unavailable")
  try {
    await services.lifecycle.beginBundledAppUpdate(bundledAppUpdateHarnessId)
    writeJson(response, 202, { accepted: true })
  } catch (cause) {
    throw conflictFrom(cause)
  }
  return true
}

// Pending-update controls: "Update Now" skips the idle wait; DELETE
// disarms a queued update entirely.
const applyPendingHarnessUpdate = async (
  services: CodevisorServerServices,
  response: ServerResponse,
  pendingApplyHarnessId: string
): Promise<boolean> => {
  if (services.lifecycle === undefined) throw new HttpFailure(501, "Harness update unavailable")
  try {
    await services.lifecycle.forcePendingUpdate(pendingApplyHarnessId)
    writeJson(response, 202, { accepted: true })
  } catch (cause) {
    throw conflictFrom(cause)
  }
  return true
}

const cancelPendingHarnessUpdate = async (
  services: CodevisorServerServices,
  response: ServerResponse,
  pendingCancelHarnessId: string
): Promise<boolean> => {
  if (services.lifecycle === undefined) throw new HttpFailure(501, "Harness update unavailable")
  try {
    await services.lifecycle.cancelPendingUpdate(pendingCancelHarnessId)
    writeJson(response, 204, undefined)
  } catch (cause) {
    throw conflictFrom(cause)
  }
  return true
}

// One-click update for CLI harnesses (origin-matched vendor flow).
const updateHarness = async (
  services: CodevisorServerServices,
  response: ServerResponse,
  updateHarnessId: string
): Promise<boolean> => {
  if (services.lifecycle === undefined) throw new HttpFailure(501, "Harness update unavailable")
  try {
    const outcome = await services.lifecycle.beginUpdate(updateHarnessId)
    writeJson(response, 202, { accepted: true, ...outcome })
  } catch (cause) {
    throw conflictFrom(cause)
  }
  return true
}

// Sessions from the harness's own on-disk store (run before/outside
// Codevisor) — onboarding workspace suggestions and chat import read these,
// NOT Codevisor's sessions table (empty on a fresh install by definition).
const listHarnessAgentSessions = async (
  services: CodevisorServerServices,
  response: ServerResponse,
  agentSessionsHarnessId: string
): Promise<boolean> => {
  const account = await services.auth?.activeAccountContext(agentSessionsHarnessId)
  writeJson(
    response,
    200,
    await run(services.agents.listAgentSessions(agentSessionsHarnessId, account))
  )
  return true
}

const updateHarnessPreference = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  request: IncomingMessage,
  response: ServerResponse,
  harnessId: string
): Promise<boolean> => {
  const payload = await readSchema(request, UpdateHarnessRequestSchema)
  if (!services.agents.catalog.some((item) => item.id === harnessId))
    throw new HttpFailure(404, "Harness not found")
  // Disabling never uninstalls: the row keeps `installed` as authored (or
  // true when this machine is the one introducing it to the catalog).
  const current = (await run(services.db.getSyncEntries(HARNESSES_SYNC_NAMESPACE))).find(
    (entry) => entry.key === harnessId && !entry.deleted
  )
  const installed =
    payload.enabled ||
    (typeof current?.value === "object" &&
      current.value !== null &&
      (current.value as Record<string, unknown>).installed !== false)
  await writeHarnessCatalog(services, config, fanout, harnessId, {
    enabled: payload.enabled,
    installed
  })
  await run(services.db.setHarnessEnabled(harnessId, payload.enabled))
  const harness = (await discoverHarnesses(services)).find(
    (candidate) => candidate.id === harnessId
  )
  if (harness === undefined) {
    throw new HttpFailure(404, `Harness not found: ${harnessId}`)
  }
  writeJson(response, 200, harness)
  return true
}

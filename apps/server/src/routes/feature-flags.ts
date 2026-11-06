import {
  FEATURE_FLAGS_NAMESPACE,
  type FeatureFlagState,
  SetFeatureFlagRequest
} from "@codevisor/api"

import { featureFlagCatalog, featureFlagStates, setFeatureFlag } from "../infra/feature-flags.js"
import { HttpFailure, matchRoute, readSchema, writeJson } from "../server-context.js"
import type { RouteContext } from "./route-context.js"
import { publishSyncEntries } from "./sync-reconcilers.js"

export const routeFeatureFlags = async (route: RouteContext): Promise<boolean> => {
  const { request, response, url, services } = route
  if (url.pathname === "/v1/feature-flags" && request.method === "GET") {
    writeJson(response, 200, { flags: await featureFlagStates(services.db) })
    return true
  }

  const id = matchRoute(url.pathname, "/v1/feature-flags/:id")
  if (id === undefined || request.method !== "PUT") return false

  const body = await readSchema(request, SetFeatureFlagRequest)
  writeJson(response, 200, await setFlag(route, id, body.enabled))
  return true
}

const setFlag = async (
  { services, fanout, config }: RouteContext,
  id: string,
  enabled: boolean
): Promise<FeatureFlagState> => {
  const flag = featureFlagCatalog.find((candidate) => candidate.id === id)
  if (flag === undefined) {
    const known = featureFlagCatalog.map((candidate) => candidate.id).join(", ")
    throw new HttpFailure(404, `Unknown feature flag: ${id}. Known flags: ${known}`)
  }

  const result = await setFeatureFlag(services.db, config.id, id, enabled)
  publishSyncEntries(services, fanout, FEATURE_FLAGS_NAMESPACE, result.changed)
  return { ...flag, enabled }
}

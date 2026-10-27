import { Schema } from "effect"

import type { PluginDiscovery } from "../plugins/discovery/plugin-discovery-boot.js"
import { HttpFailure, matchRoute, readSchema, writeJson } from "../server-context.js"
import type { RouteContext } from "./route-context.js"

export const routePluginDiscovery = async (route: RouteContext): Promise<boolean> => {
  const { request, url } = route
  if (request.method === "GET" && url.pathname === "/v1/plugins/search") {
    const query = url.searchParams.get("query") ?? undefined
    return respond(route, { items: await requireDiscovery(route).directory.search(query) })
  }
  const described = matchRoute(url.pathname, "/v1/plugins/describe/:plugin")
  if (request.method === "GET" && described !== undefined) {
    return respond(route, await requireDescription(requireDiscovery(route), described))
  }
  if (request.method === "POST" && url.pathname === "/v1/plugins/setup-requests") {
    const body = await readSchema(request, SetupRequestBody)
    return respond(route, await requireDiscovery(route).setup.request(setupInput(body)))
  }
  return false
}

export const defaultSetupWaitMs = 5 * 60_000
const maxSetupWaitMs = 9 * 60_000

const SetupRequestBody = Schema.Struct({
  sessionId: Schema.String,
  plugin: Schema.String,
  reason: Schema.String,
  waitMs: Schema.optional(Schema.Number)
})

const setupInput = (body: typeof SetupRequestBody.Type) => ({
  sessionId: body.sessionId,
  plugin: body.plugin,
  reason: body.reason,
  waitMs: Math.max(0, Math.min(maxSetupWaitMs, body.waitMs ?? defaultSetupWaitMs))
})

const requireDescription = async (discovery: PluginDiscovery, plugin: string) => {
  const description = await discovery.directory.describe(plugin)
  if (description !== undefined) return description
  throw new HttpFailure(404, `No plugin named "${plugin}". Search with plugins.search.`)
}

const respond = (route: RouteContext, body: unknown): boolean => {
  writeJson(route.response, 200, body)
  return true
}

const requireDiscovery = (route: RouteContext): PluginDiscovery => {
  const discovery = route.routeState.pluginDiscovery
  if (discovery === undefined) throw new HttpFailure(501, "Plugins unavailable")
  return discovery
}

import type { IncomingMessage, ServerResponse } from "node:http"

import type { PluginRegistryIndex } from "@codevisor/api"
import {
  DiscoverRemotePluginRequest as DiscoverRemotePluginRequestSchema,
  ImportRemotePluginRequest as ImportRemotePluginRequestSchema,
  LinkPluginRequest as LinkPluginRequestSchema
} from "@codevisor/api"
import { filterPluginRegistryIndex } from "@codevisor/plugins"
import type { PluginsManager } from "@codevisor/plugins"

import {
  HttpFailure,
  readSchema,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"
import { publishPluginUpdated, withOpenPaneCount } from "./plugin-panes.js"
import { routePlugin } from "./plugin-routes.js"
import { isRoute, rejectSyncThrows } from "./route-context.js"
import type { RouteContext } from "./route-context.js"

export const routePluginProxy = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (services.plugins === undefined) {
    return false
  }
  return services.plugins.handleProxyRequest(request, response, url)
}

export const routePlugins = (route: RouteContext): Promise<boolean> =>
  rejectSyncThrows(() => dispatchPluginRoute(route))

const dispatchPluginRoute = (route: RouteContext): Promise<boolean> => {
  const { services, request, url } = route
  if (!url.pathname.startsWith("/v1/plugins")) return Promise.resolve(false)

  if (isRoute(url, request, "/v1/plugins/registry", "GET")) return readRegistry(route)

  const manager = services.plugins
  if (manager === undefined) throw new HttpFailure(501, "Plugins are unavailable")

  return routePluginCollection(route, manager) ?? routePlugin(route, manager)
}

const routePluginCollection = (
  route: RouteContext,
  manager: PluginsManager
): Promise<boolean> | undefined => {
  const { request, url } = route
  if (isRoute(url, request, "/v1/plugins", "GET")) return listPlugins(route, manager)

  if (isRoute(url, request, "/v1/plugins/updates", "GET")) return listUpdates(route, manager)

  if (isRoute(url, request, "/v1/plugins/discover-remote", "POST"))
    return discoverRemote(route, manager)

  if (isRoute(url, request, "/v1/plugins/import-remote", "POST"))
    return importRemote(route, manager)

  if (isRoute(url, request, "/v1/plugins/link", "POST")) return linkPlugin(route, manager)
  return undefined
}

const readRegistry = async ({ services, response, url }: RouteContext): Promise<boolean> => {
  const registry = services.pluginRegistry
  if (registry === undefined) throw new HttpFailure(501, "The plugin registry is unavailable")

  const index = await registry.fetchIndex()
  const query = url.searchParams.get("q")
  writeJson(response, 200, registryMatching(index, query))
  return true
}

const listPlugins = async (
  { services, response }: RouteContext,
  manager: PluginsManager
): Promise<boolean> => {
  const list = await manager.list()
  writeJson(response, 200, {
    plugins: await Promise.all(list.plugins.map((summary) => withOpenPaneCount(services, summary)))
  })
  return true
}

const listUpdates = async (
  { response }: RouteContext,
  manager: PluginsManager
): Promise<boolean> => {
  writeJson(response, 200, await manager.listUpdates())
  return true
}

const discoverRemote = async (
  { request, response }: RouteContext,
  manager: PluginsManager
): Promise<boolean> => {
  writeJson(
    response,
    200,
    await manager.discoverRemote(await readSchema(request, DiscoverRemotePluginRequestSchema))
  )
  return true
}

const importRemote = async (route: RouteContext, manager: PluginsManager): Promise<boolean> => {
  const imported = await manager.importRemote(
    await readSchema(route.request, ImportRemotePluginRequestSchema)
  )

  await publishPluginUpdated(route, imported)

  writeJson(route.response, 201, imported)
  return true
}

const linkPlugin = async (route: RouteContext, manager: PluginsManager): Promise<boolean> => {
  const linked = await manager.link(await readSchema(route.request, LinkPluginRequestSchema))

  await publishPluginUpdated(route, linked)

  writeJson(route.response, 201, linked)
  return true
}

const registryMatching = (
  index: PluginRegistryIndex,
  query: string | null
): PluginRegistryIndex => {
  if (query === null) return index
  return filterPluginRegistryIndex(index, query)
}

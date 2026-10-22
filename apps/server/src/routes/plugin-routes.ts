import type { ServerResponse } from "node:http"

import type { InvokePluginToolRequest } from "@codevisor/api"
import {
  ApplyPluginUpdateRequest as ApplyPluginUpdateRequestSchema,
  InvokePluginToolRequest as InvokePluginToolRequestSchema,
  PluginPaneTokenRequest as PluginPaneTokenRequestSchema,
  SetPluginEnabledRequest as SetPluginEnabledRequestSchema
} from "@codevisor/api"
import type {
  PluginIconAsset,
  PluginsManager,
  PluginToolInvocationContext
} from "@codevisor/plugins"

import { matchRoute, readSchema, writeJson } from "../server-context.js"
import { deletePluginPanes, publishPluginUpdated, withOpenPaneCount } from "./plugin-panes.js"
import { methodRouteId, methodRouteParams, whenMethod } from "./route-context.js"
import type { RouteContext } from "./route-context.js"
import { routeParam } from "./route-params.js"

type RouteParams = Readonly<Record<string, string>>

export const routePlugin = (route: RouteContext, manager: PluginsManager): Promise<boolean> =>
  routePluginAssets(route, manager) ??
  routePluginLifecycle(route, manager) ??
  routePluginUpdate(route, manager) ??
  routePluginRecord(route, manager) ??
  Promise.resolve(false)

const routePluginAssets = (
  route: RouteContext,
  manager: PluginsManager
): Promise<boolean> | undefined => {
  const tokenRoute = methodRouteParams(route, "POST", "/v1/plugins/:pluginId/panes/:paneId/token")
  if (tokenRoute !== undefined) return issuePaneToken(route, manager, tokenRoute)

  const paneIconRoute = methodRouteParams(
    route,
    "GET",
    "/v1/plugins/:pluginId/panes/:paneType/icon"
  )
  if (paneIconRoute !== undefined) return readPaneIcon(route, manager, paneIconRoute)

  const pluginIconId = methodRouteId(route, "GET", "/v1/plugins/:pluginId/icon")
  if (pluginIconId !== undefined) return readPluginIcon(route, manager, pluginIconId)

  const toolRoute = methodRouteParams(route, "POST", "/v1/plugins/:pluginId/tools/:toolName")
  if (toolRoute !== undefined) return invokeTool(route, manager, toolRoute)
  return undefined
}

const routePluginLifecycle = (
  route: RouteContext,
  manager: PluginsManager
): Promise<boolean> | undefined => {
  const unlinkId = methodRouteId(route, "DELETE", "/v1/plugins/:pluginId/link")
  if (unlinkId !== undefined) return unlinkPlugin(route, manager, unlinkId)

  const restartId = methodRouteId(route, "POST", "/v1/plugins/:pluginId/restart")
  if (restartId !== undefined) return restartPlugin(route, manager, restartId)

  const restoreId = methodRouteId(route, "POST", "/v1/plugins/:pluginId/restore")
  if (restoreId !== undefined) return restorePlugin(route, manager, restoreId)

  const enabledId = methodRouteId(route, "POST", "/v1/plugins/:pluginId/set-enabled")
  if (enabledId !== undefined) return setPluginEnabled(route, manager, enabledId)
  return undefined
}

const routePluginUpdate = (
  route: RouteContext,
  manager: PluginsManager
): Promise<boolean> | undefined => {
  const prepareUpdateId = methodRouteId(route, "POST", "/v1/plugins/:pluginId/update/prepare")
  if (prepareUpdateId !== undefined) return prepareUpdate(route, manager, prepareUpdateId)

  const applyUpdateId = methodRouteId(route, "POST", "/v1/plugins/:pluginId/update/apply")
  if (applyUpdateId !== undefined) return applyUpdate(route, manager, applyUpdateId)
  return undefined
}

const routePluginRecord = (
  route: RouteContext,
  manager: PluginsManager
): Promise<boolean> | undefined => {
  const { request, url } = route
  const pluginId = matchRoute(url.pathname, "/v1/plugins/:pluginId")
  const readId = whenMethod(request, "GET", pluginId)
  if (readId !== undefined) return readPlugin(route, manager, readId)

  const removeId = whenMethod(request, "DELETE", pluginId)
  if (removeId !== undefined) return removePlugin(route, manager, removeId)
  return undefined
}

const issuePaneToken = async (
  { request, response, url }: RouteContext,
  manager: PluginsManager,
  params: RouteParams
): Promise<boolean> => {
  const payload = await readSchema(request, PluginPaneTokenRequestSchema)
  const issued = await manager.issuePaneToken(
    routeParam(params, "pluginId"),
    routeParam(params, "paneId"),
    payload
  )
  writeJson(response, 201, { ...issued, url: `${url.origin}${issued.path}` })
  return true
}

const readPaneIcon = async (
  { response }: RouteContext,
  manager: PluginsManager,
  params: RouteParams
): Promise<boolean> => {
  const icon = await manager.fetchIcon(
    routeParam(params, "pluginId"),
    routeParam(params, "paneType")
  )
  writeIcon(response, icon)
  return true
}

const readPluginIcon = async (
  { response }: RouteContext,
  manager: PluginsManager,
  pluginId: string
): Promise<boolean> => {
  const icon = await manager.fetchIcon(pluginId)
  writeIcon(response, icon)
  return true
}

const invokeTool = async (
  { request, response }: RouteContext,
  manager: PluginsManager,
  params: RouteParams
): Promise<boolean> => {
  const payload = await readSchema(request, InvokePluginToolRequestSchema)
  const args = payload.args ?? {}
  const context = toolContext(payload)
  const result = await manager.invokeTool(
    routeParam(params, "pluginId"),
    routeParam(params, "toolName"),
    args,
    context
  )
  writeJson(response, 200, result)
  return true
}

const unlinkPlugin = async (
  { services, fanout, response }: RouteContext,
  manager: PluginsManager,
  pluginId: string
): Promise<boolean> => {
  const summary = await manager.get(pluginId)

  await deletePluginPanes(services, fanout, summary.id)

  writeJson(response, 200, await manager.unlink(pluginId))
  return true
}

const restartPlugin = async (
  route: RouteContext,
  manager: PluginsManager,
  pluginId: string
): Promise<boolean> => {
  const restarted = await manager.restart(pluginId)

  await publishPluginUpdated(route, restarted)

  writeJson(route.response, 200, restarted)
  return true
}

const restorePlugin = async (
  route: RouteContext,
  manager: PluginsManager,
  pluginId: string
): Promise<boolean> => {
  const restored = await manager.restore(pluginId)

  await publishPluginUpdated(route, restored)

  writeJson(route.response, 200, restored)
  return true
}

const setPluginEnabled = async (
  route: RouteContext,
  manager: PluginsManager,
  pluginId: string
): Promise<boolean> => {
  const payload = await readSchema(route.request, SetPluginEnabledRequestSchema)
  const changed = await manager.setEnabled(pluginId, payload.enabled)

  await publishPluginUpdated(route, changed)

  writeJson(route.response, 200, changed)
  return true
}

const prepareUpdate = async (
  { response }: RouteContext,
  manager: PluginsManager,
  pluginId: string
): Promise<boolean> => {
  writeJson(response, 201, await manager.prepareUpdate(pluginId))
  return true
}

const applyUpdate = async (
  route: RouteContext,
  manager: PluginsManager,
  pluginId: string
): Promise<boolean> => {
  const payload = await readSchema(route.request, ApplyPluginUpdateRequestSchema)
  const updated = await manager.applyUpdate(pluginId, payload.planId)

  await publishPluginUpdated(route, updated)

  writeJson(route.response, 200, updated)
  return true
}

const readPlugin = async (
  { services, response }: RouteContext,
  manager: PluginsManager,
  pluginId: string
): Promise<boolean> => {
  writeJson(response, 200, await withOpenPaneCount(services, await manager.get(pluginId)))
  return true
}

const removePlugin = async (
  { services, fanout, response }: RouteContext,
  manager: PluginsManager,
  pluginId: string
): Promise<boolean> => {
  const summary = await manager.get(pluginId)

  await deletePluginPanes(services, fanout, summary.id)

  writeJson(response, 200, await manager.remove(pluginId))
  return true
}

const toolContext = (payload: InvokePluginToolRequest): PluginToolInvocationContext => ({
  ...(payload.cwd === undefined ? {} : { cwd: payload.cwd }),
  ...(payload.workspaceId === undefined ? {} : { workspaceId: payload.workspaceId })
})

const writeIcon = (response: ServerResponse, icon: PluginIconAsset): void => {
  response.writeHead(200, {
    "Cache-Control": "private, max-age=300",
    "Content-Length": String(icon.data.byteLength),
    "Content-Type": icon.contentType
  })
  response.end(icon.data)
}

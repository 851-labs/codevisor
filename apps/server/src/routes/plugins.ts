import type { PluginSummary, WorkspacePane } from "@codevisor/api"
import { filterPluginRegistryIndex } from "@codevisor/plugins"
import {
  ApplyPluginUpdateRequest as ApplyPluginUpdateRequestSchema,
  DiscoverRemotePluginRequest as DiscoverRemotePluginRequestSchema,
  ImportRemotePluginRequest as ImportRemotePluginRequestSchema,
  InvokePluginToolRequest as InvokePluginToolRequestSchema,
  LinkPluginRequest as LinkPluginRequestSchema,
  PluginPaneTokenRequest as PluginPaneTokenRequestSchema
} from "@codevisor/api"
import type { IncomingMessage, ServerResponse } from "node:http"
import {
  appendAndPublish,
  HttpFailure,
  matchRoute,
  matchRouteParams,
  readSchema,
  run,
  writeJson,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"

/// Pane webview traffic: `ANY /v1/plugins/:pluginId/app/*`. Routed BEFORE
/// bearer authorization — webview subresource loads cannot carry the machine
/// token (and the cloud relay strips Authorization), so the proxy
/// authenticates with per-pane tokens and scoped cookies instead.
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

/// The workspace pane records rendering this plugin, across all workspaces.
/// Pane records carry the plugin as `providerId: "plugin:<pluginId>"`.
const listPluginPanes = async (
  services: CodevisorServerServices,
  pluginId: string
): Promise<ReadonlyArray<WorkspacePane>> => {
  const providerId = `plugin:${pluginId}`
  return (await run(services.db.listWorkspacePanes)).filter(
    (pane) => pane.providerId === providerId
  )
}

/// Plugin summaries leave the manager without database knowledge; the route
/// layer adds how many open pane records point at each plugin so clients can
/// warn before an uninstall closes them.
const withOpenPaneCount = async (
  services: CodevisorServerServices,
  summary: PluginSummary
): Promise<PluginSummary> => ({
  ...summary,
  openPaneCount: (await listPluginPanes(services, summary.id)).length
})

/// Uninstalling a plugin orphans its pane records — clients would show dead
/// tabs forever. Delete each record and publish the same events the pane
/// close flow does, so every connected client closes those tabs.
const deletePluginPanes = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  pluginId: string
): Promise<void> => {
  for (const pane of await listPluginPanes(services, pluginId)) {
    const replacement = await run(services.db.deleteWorkspacePane(pane.workspaceId, pane.id))
    if (replacement !== undefined) {
      // A workspace's final pane converts into a New Tab instead of vanishing.
      await appendAndPublish(
        services.db,
        fanout,
        "workspace.pane.updated",
        replacement.id,
        replacement
      )
    } else {
      await appendAndPublish(services.db, fanout, "workspace.pane.deleted", pane.id, {
        id: pane.id,
        workspaceId: pane.workspaceId
      })
    }
  }
}

/// Management routes (list, detail, pane-token issue, install pipeline).
/// These sit behind the normal bearer authorization like every other /v1
/// route.
export const routePlugins = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (!url.pathname.startsWith("/v1/plugins")) {
    return false
  }

  // Registry passthrough: the machine (not the client) talks to the hosted
  // index, so apps browse plugins with no cloud connectivity of their own.
  // Independent of the runtime manager — handled before its 501 gate.
  if (url.pathname === "/v1/plugins/registry" && request.method === "GET") {
    const registry = services.pluginRegistry
    if (registry === undefined) {
      throw new HttpFailure(501, "The plugin registry is unavailable")
    }
    const index = await registry.fetchIndex()
    const query = url.searchParams.get("q")
    writeJson(response, 200, query === null ? index : filterPluginRegistryIndex(index, query))
    return true
  }

  const manager = services.plugins
  if (manager === undefined) {
    throw new HttpFailure(501, "Plugins are unavailable")
  }

  if (url.pathname === "/v1/plugins" && request.method === "GET") {
    const list = await manager.list()
    writeJson(response, 200, {
      plugins: await Promise.all(
        list.plugins.map((summary) => withOpenPaneCount(services, summary))
      )
    })
    return true
  }

  if (url.pathname === "/v1/plugins/updates" && request.method === "GET") {
    writeJson(response, 200, await manager.listUpdates())
    return true
  }

  if (url.pathname === "/v1/plugins/discover-remote" && request.method === "POST") {
    writeJson(
      response,
      200,
      await manager.discoverRemote(await readSchema(request, DiscoverRemotePluginRequestSchema))
    )
    return true
  }

  if (url.pathname === "/v1/plugins/import-remote" && request.method === "POST") {
    const imported = await manager.importRemote(
      await readSchema(request, ImportRemotePluginRequestSchema)
    )
    // The plugin's code changed on disk: tell clients to reload open panes.
    await appendAndPublish(services.db, fanout, "plugin.updated", imported.id, imported)
    writeJson(response, 201, imported)
    return true
  }

  if (url.pathname === "/v1/plugins/link" && request.method === "POST") {
    const linked = await manager.link(await readSchema(request, LinkPluginRequestSchema))
    // Re-linking a dev checkout is the "I changed the code" gesture too.
    await appendAndPublish(services.db, fanout, "plugin.updated", linked.id, linked)
    writeJson(response, 201, linked)
    return true
  }

  const tokenRoute = matchRouteParams(url.pathname, "/v1/plugins/:pluginId/panes/:paneId/token")
  if (tokenRoute !== undefined && request.method === "POST") {
    const payload = await readSchema(request, PluginPaneTokenRequestSchema)
    /* v8 ignore next 5 -- both pattern captures are guaranteed by the matched route. */
    const issued = await manager.issuePaneToken(
      tokenRoute.pluginId ?? "",
      tokenRoute.paneId ?? "",
      payload
    )
    // The manager only knows server-relative paths; the route layer knows the
    // origin the caller actually reached (Host header), so it adds the
    // absolute URL browser tooling can open directly.
    writeJson(response, 201, { ...issued, url: `${url.origin}${issued.path}` })
    return true
  }

  const paneIconRoute = matchRouteParams(url.pathname, "/v1/plugins/:pluginId/panes/:paneType/icon")
  if (paneIconRoute !== undefined && request.method === "GET") {
    /* v8 ignore next 2 -- both captures exist when the route matches. */
    const icon = await manager.fetchIcon(paneIconRoute.pluginId ?? "", paneIconRoute.paneType ?? "")
    response.writeHead(200, {
      "Cache-Control": "private, max-age=300",
      "Content-Length": String(icon.data.byteLength),
      "Content-Type": icon.contentType
    })
    response.end(icon.data)
    return true
  }

  const pluginIconId = matchRoute(url.pathname, "/v1/plugins/:pluginId/icon")
  if (pluginIconId !== undefined && request.method === "GET") {
    const icon = await manager.fetchIcon(pluginIconId)
    response.writeHead(200, {
      "Cache-Control": "private, max-age=300",
      "Content-Length": String(icon.data.byteLength),
      "Content-Type": icon.contentType
    })
    response.end(icon.data)
    return true
  }

  const toolRoute = matchRouteParams(url.pathname, "/v1/plugins/:pluginId/tools/:toolName")
  if (toolRoute !== undefined && request.method === "POST") {
    const payload = await readSchema(request, InvokePluginToolRequestSchema)
    const args = payload.args ?? {}
    const context = {
      ...(payload.cwd === undefined ? {} : { cwd: payload.cwd }),
      ...(payload.workspaceId === undefined ? {} : { workspaceId: payload.workspaceId })
    }
    /* v8 ignore next 2 -- both pattern captures are guaranteed by the matched route. */
    const result = await manager.invokeTool(
      toolRoute.pluginId ?? "",
      toolRoute.toolName ?? "",
      args,
      context
    )
    // The tool's own response body, verbatim — plugins define their shapes.
    writeJson(response, 200, result)
    return true
  }

  const restartId = matchRoute(url.pathname, "/v1/plugins/:pluginId/restart")
  if (restartId !== undefined && request.method === "POST") {
    const restarted = await manager.restart(restartId)
    // Restart is the manual "pick up my changes" action; open panes reload.
    // Runtime state transitions stay separate because crash recovery should
    // not reload a healthy webview unless the user explicitly restarts it.
    await appendAndPublish(services.db, fanout, "plugin.updated", restarted.id, restarted)
    writeJson(response, 200, restarted)
    return true
  }

  const prepareUpdateId = matchRoute(url.pathname, "/v1/plugins/:pluginId/update/prepare")
  if (prepareUpdateId !== undefined && request.method === "POST") {
    writeJson(response, 201, await manager.prepareUpdate(prepareUpdateId))
    return true
  }

  const applyUpdateId = matchRoute(url.pathname, "/v1/plugins/:pluginId/update/apply")
  if (applyUpdateId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, ApplyPluginUpdateRequestSchema)
    const updated = await manager.applyUpdate(applyUpdateId, payload.planId)
    await appendAndPublish(services.db, fanout, "plugin.updated", updated.id, updated)
    writeJson(response, 200, updated)
    return true
  }

  const pluginId = matchRoute(url.pathname, "/v1/plugins/:pluginId")
  if (pluginId !== undefined && request.method === "GET") {
    writeJson(response, 200, await withOpenPaneCount(services, await manager.get(pluginId)))
    return true
  }
  if (pluginId !== undefined && request.method === "DELETE") {
    // Ensure the plugin exists (404s propagate) before touching pane records.
    const summary = await manager.get(pluginId)
    await deletePluginPanes(services, fanout, summary.id)
    writeJson(response, 200, await manager.remove(pluginId))
    return true
  }

  return false
}

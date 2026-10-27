import type { ServerResponse } from "node:http"

import type { McpManager } from "@codevisor/mcp"
import { Schema } from "effect"

import type { PluginAppScope } from "../plugins/apps/plugin-app-tokens.js"
import {
  makePluginApps,
  type AppDisplay,
  type AppDisplayMode,
  type PluginApps
} from "../plugins/apps/plugin-apps.js"
import {
  HttpFailure,
  matchRouteParams,
  readSchema,
  writeFailure,
  writeJson
} from "../server-context.js"
import type { RouteContext, RouteHandler } from "./route-context.js"

export const pluginAppRouteFor = (route: RouteContext): RouteHandler | undefined => {
  const scoped = scopedRequest(route)
  if (scoped === undefined) return undefined
  return async (matched) => {
    try {
      await appActions[scoped.action](matched, scoped.authorize(matched))
    } catch (cause) {
      writeFailure(matched.response, cause)
    }
  }
}

export const routePluginApps = async (route: RouteContext): Promise<boolean> => {
  if (route.request.method !== "POST") return false

  const view = matchRouteParams(route.url.pathname, "/v1/plugins/apps/:viewId/token")
  if (view !== undefined) {
    writeJson(route.response, 200, await appsFor(route).launchView(view.viewId!))
    return true
  }
  const pane = matchRouteParams(route.url.pathname, "/v1/plugins/:serverId/panes/:paneType/token")
  if (pane === undefined) return false
  writeJson(route.response, 200, await appsFor(route).launchPane(pane.serverId!, pane.paneType!))
  return true
}

type AppAction = "shell" | "tools/call" | "resources/read" | "model-context"

interface ScopedRequest {
  readonly action: AppAction
  readonly authorize: (route: RouteContext) => PluginAppScope
}

const actionRoutes: ReadonlyArray<{
  readonly suffix: string
  readonly method: string
  readonly action: AppAction
}> = [
  { suffix: "", method: "GET", action: "shell" },
  { suffix: "/tools/call", method: "POST", action: "tools/call" },
  { suffix: "/resources/read", method: "POST", action: "resources/read" },
  { suffix: "/model-context", method: "POST", action: "model-context" }
]

const APP_TOKEN_HEADER = "x-codevisor-app-token"

const expiredLink = "This app link has expired; reopen the app"

const ToolCallBody = Schema.Struct({
  name: Schema.String,
  arguments: Schema.optional(Schema.Record(Schema.String, Schema.Unknown))
})

const ResourceReadBody = Schema.Struct({ uri: Schema.String })

const ModelContextBody = Schema.Struct({
  content: Schema.optional(Schema.Array(Schema.Unknown)),
  structuredContent: Schema.optional(Schema.Record(Schema.String, Schema.Unknown))
})

const appsByManager = new WeakMap<McpManager, PluginApps>()

const appsFor = ({ services }: RouteContext): PluginApps => {
  if (services.mcp === undefined) throw new HttpFailure(501, "Plugins unavailable")
  let apps = appsByManager.get(services.mcp)
  if (apps === undefined) {
    apps = makePluginApps(services.mcp, services.db)
    appsByManager.set(services.mcp, apps)
  }
  return apps
}

const scopedRequest = ({ request, url }: RouteContext): ScopedRequest | undefined => {
  for (const { suffix, method, action } of actionRoutes) {
    if (request.method !== method) continue
    const view = matchRouteParams(url.pathname, `/v1/plugins/apps/:viewId${suffix}`)
    if (view !== undefined) return { action, authorize: viewAuthorizer(view.viewId!) }
    const pane = matchRouteParams(url.pathname, `/v1/plugins/panes/:token${suffix}`)
    if (pane !== undefined) return { action, authorize: paneAuthorizer(pane.token!) }
  }
  return undefined
}

const viewAuthorizer =
  (viewId: string) =>
  (route: RouteContext): PluginAppScope =>
    appsFor(route).authorize(scopedToken(route), { kind: "view", viewId })

const paneAuthorizer =
  (token: string) =>
  (route: RouteContext): PluginAppScope => {
    const scope = appsFor(route).authorize(token)
    if (scope.kind !== "pane") throw new HttpFailure(401, expiredLink)
    return scope
  }

const scopedToken = ({ request, url }: RouteContext): string | null => {
  const header = request.headers[APP_TOKEN_HEADER]
  if (typeof header === "string") return header
  return url.searchParams.get("token")
}

const appActions: Readonly<
  Record<AppAction, (route: RouteContext, scope: PluginAppScope) => Promise<void>>
> = {
  shell: async (route, scope) => {
    const shell = await appsFor(route).render(scope, display(route.url))
    writeHtml(route.response, shell.html, shell.policy)
  },
  "tools/call": async (route, scope) => {
    const body = await readSchema(route.request, ToolCallBody)
    writeJson(route.response, 200, await appsFor(route).callTool(scope, body))
  },
  "resources/read": async (route, scope) => {
    const body = await readSchema(route.request, ResourceReadBody)
    writeJson(route.response, 200, await appsFor(route).readResource(scope, body.uri))
  },
  "model-context": async (route, scope) => {
    const body = await readSchema(route.request, ModelContextBody)
    await appsFor(route).saveModelContext(scope, body)
    writeJson(route.response, 200, {})
  }
}

const writeHtml = (response: ServerResponse, html: string, policy: string): void => {
  response.writeHead(200, {
    "content-type": "text/html; charset=utf-8",
    "content-security-policy": policy,
    "cache-control": "no-store",
    "referrer-policy": "no-referrer",
    "x-content-type-options": "nosniff"
  })
  response.end(html)
}

const localePattern = /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$/

const displayModes: ReadonlyArray<AppDisplayMode> = ["inline", "fullscreen", "pip"]

const displayModeOf = (value: string | null): AppDisplayMode | undefined =>
  displayModes.find((mode) => mode === value)

const hostModes = (value: string | null): ReadonlyArray<AppDisplayMode> =>
  (value ?? "").split(",").flatMap((mode) => displayModeOf(mode.trim()) ?? [])

const display = (url: URL): AppDisplay => {
  const query = url.searchParams
  const displayMode = displayModeOf(query.get("displayMode"))
  const locale = query.get("locale")
  return {
    theme: query.get("theme") === "dark" ? "dark" : "light",
    platform: query.get("platform") === "mobile" ? "mobile" : "desktop",
    modes: hostModes(query.get("modes")),
    ...(displayMode === undefined ? {} : { displayMode }),
    ...(locale !== null && localePattern.test(locale) ? { locale } : {})
  }
}

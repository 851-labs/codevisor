import type { CodevisorDatabaseService } from "@codevisor/db"
import type { McpManager, PluginAppView } from "@codevisor/mcp"
import type { ReadResourceResult } from "@modelcontextprotocol/sdk/types.js"

import { HttpFailure, run } from "../../server-context.js"
import type { BridgeBoot } from "./plugin-app-bridge.js"
import {
  appPolicy,
  appSandbox,
  frameAllow,
  shellPolicy,
  type AppSandbox
} from "./plugin-app-csp.js"
import { openAiGlobals, openAiShimScript } from "./plugin-app-openai.js"
import { appShellHtml, policyMeta, scriptJson, withPreamble } from "./plugin-app-shell.js"
import {
  APP_LAUNCH_TTL_MS,
  APP_SESSION_TTL_MS,
  makePluginAppTokens,
  sameScope,
  type PluginAppScope,
  type PluginAppTokens
} from "./plugin-app-tokens.js"

export const APP_PROTOCOL_VERSION = "2026-01-26"

export interface AppLaunch {
  readonly url: string
  readonly expiresAt: string
}

export type AppDisplayMode = "inline" | "fullscreen" | "pip"

export interface AppDisplay {
  readonly theme: "light" | "dark"
  readonly displayMode?: AppDisplayMode
  readonly modes: ReadonlyArray<AppDisplayMode>
  readonly platform: "desktop" | "mobile"
  readonly locale?: string
}

export interface ModelContextBody {
  readonly content?: ReadonlyArray<unknown> | undefined
  readonly structuredContent?: Readonly<Record<string, unknown>> | undefined
}

export interface RenderedShell {
  readonly html: string
  readonly policy: string
}

export interface ToolCallBody {
  readonly name: string
  readonly arguments?: Readonly<Record<string, unknown>> | undefined
}

export interface PluginApps {
  readonly launchView: (viewId: string) => Promise<AppLaunch>
  readonly launchPane: (serverId: string, paneType: string) => Promise<AppLaunch>
  readonly authorize: (token: string | null, expected?: PluginAppScope) => PluginAppScope
  readonly render: (scope: PluginAppScope, display: AppDisplay) => Promise<RenderedShell>
  readonly callTool: (scope: PluginAppScope, body: ToolCallBody) => Promise<unknown>
  readonly readResource: (scope: PluginAppScope, uri: string) => Promise<ReadResourceResult>
  readonly saveModelContext: (scope: PluginAppScope, body: ModelContextBody) => Promise<void>
}

export const makePluginApps = (
  mcp: McpManager,
  db: CodevisorDatabaseService,
  tokens: PluginAppTokens = makePluginAppTokens()
): PluginApps => {
  const target = (scope: PluginAppScope): Promise<AppTarget> => {
    if (scope.kind === "view") return viewTarget(mcp, scope.viewId)
    return paneTarget(mcp, scope.serverId, scope.paneType)
  }

  return {
    launchView: async (viewId) => {
      const scope: PluginAppScope = { kind: "view", viewId }
      await target(scope)
      const issued = tokens.issue(scope, APP_LAUNCH_TTL_MS)
      return { url: `${viewPath(viewId)}?token=${issued.token}`, expiresAt: issued.expiresAt }
    },
    launchPane: async (serverId, paneType) => {
      const scope: PluginAppScope = { kind: "pane", serverId, paneType }
      await target(scope)
      const issued = tokens.issue(scope, APP_LAUNCH_TTL_MS)
      return { url: `${panePath(issued.token)}/`, expiresAt: issued.expiresAt }
    },
    authorize: (token, expected) => {
      const scope = token === null ? undefined : tokens.verify(token)
      if (scope === undefined || (expected !== undefined && !sameScope(scope, expected))) {
        throw new HttpFailure(401, "This app link has expired; reopen the app")
      }
      return scope
    },
    render: async (scope, display) => {
      const found = await target(scope)
      const resource = appResource(
        found.resourceUri,
        await mcp.readResource(found.serverId, found.resourceUri, found.accountId)
      )
      const sandbox = appSandbox(resource.meta)
      const session = tokens.issue(scope, APP_SESSION_TTL_MS)
      const boot = shellBoot({
        found,
        html: resource.html,
        sandbox,
        display,
        scope,
        token: session.token
      })
      return { html: appShellHtml(boot), policy: shellPolicy(sandbox.csp) }
    },
    callTool: async (scope, body) => {
      const found = await target(scope)
      return mcp.callAppTool(found.serverId, body.name, { ...body.arguments }, found.accountId)
    },
    readResource: async (scope, uri) => {
      const found = await target(scope)
      return mcp.readResource(found.serverId, uri, found.accountId)
    },
    saveModelContext: async (scope, body) => {
      const view = (await target(scope)).view
      if (view === undefined) throw new HttpFailure(409, "A pane has no chat to give context to")
      await run(
        db.savePluginAppContext({
          sessionId: view.sessionId,
          viewId: view.viewId,
          plugin: view.serverName,
          tool: view.toolName,
          context: modelContext(body)
        })
      )
    }
  }
}

interface AppTarget {
  readonly serverId: string
  readonly resourceUri: string
  readonly displayMode: AppDisplayMode
  readonly accountId: string | undefined
  readonly view?: PluginAppView
}

interface AppResource {
  readonly html: string
  readonly meta: unknown
}

const hostInfo = { name: "Codevisor", version: "1.0.0" }

const viewPath = (viewId: string): string => `/v1/plugins/apps/${encodeURIComponent(viewId)}`

const panePath = (token: string): string => `/v1/plugins/panes/${token}`

const viewTarget = async (mcp: McpManager, viewId: string): Promise<AppTarget> => {
  const view = await mcp.appView(viewId)
  if (view === undefined) throw new HttpFailure(404, "This app view is no longer available")
  return {
    serverId: view.serverId,
    resourceUri: view.resourceUri,
    displayMode: "inline",
    accountId: view.accountId,
    view
  }
}

const paneTarget = async (
  mcp: McpManager,
  serverId: string,
  paneType: string
): Promise<AppTarget> => {
  const server = (await mcp.list()).find((candidate) => candidate.id === serverId)
  const pane = server?.capabilities?.panes.find((candidate) => candidate.type === paneType)
  if (pane === undefined) throw new HttpFailure(404, `No ${paneType} pane for this plugin`)
  return {
    serverId,
    resourceUri: pane.resourceUri,
    displayMode: "fullscreen",
    accountId: undefined
  }
}

const appResource = (uri: string, result: ReadResourceResult): AppResource => {
  const content = result.contents.find((candidate) => candidate.mimeType?.startsWith("text/html"))
  if (content === undefined) throw new HttpFailure(502, `${uri} isn't an HTML app`)
  const html =
    "text" in content ? content.text : Buffer.from(content.blob, "base64").toString("utf8")
  return { html, meta: content._meta }
}

const endpoints = (scope: PluginAppScope, token: string): BridgeBoot["endpoints"] => {
  if (scope.kind === "view") {
    const base = viewPath(scope.viewId)
    return {
      toolsCall: `${base}/tools/call?token=${token}`,
      resourcesRead: `${base}/resources/read?token=${token}`,
      modelContext: `${base}/model-context?token=${token}`
    }
  }
  return {
    toolsCall: `${panePath(token)}/tools/call`,
    resourcesRead: `${panePath(token)}/resources/read`,
    modelContext: `${panePath(token)}/model-context`
  }
}

interface ShellParts {
  readonly found: AppTarget
  readonly html: string
  readonly sandbox: AppSandbox
  readonly display: AppDisplay
  readonly scope: PluginAppScope
  readonly token: string
}

const shellBoot = ({ found, html, sandbox, display, scope, token }: ShellParts): BridgeBoot => {
  const context = hostContext(found, display)
  return {
    protocolVersion: APP_PROTOCOL_VERSION,
    hostInfo,
    hostCapabilities: {
      openLinks: {},
      serverTools: {},
      serverResources: {},
      logging: {},
      sandbox: { permissions: sandbox.permissions, csp: sandbox.csp }
    },
    hostContext: context,
    html: withPreamble(html, appPreamble(sandbox, context, found.view)),
    allow: frameAllow(sandbox.permissions),
    token,
    endpoints: endpoints(scope, token),
    ...(found.view === undefined
      ? {}
      : {
          viewId: found.view.viewId,
          toolInput: found.view.toolInput,
          toolResult: found.view.toolResult
        })
  }
}

const appPreamble = (
  sandbox: AppSandbox,
  context: Readonly<Record<string, unknown>>,
  view: PluginAppView | undefined
): string =>
  policyMeta(appPolicy(sandbox.csp)) + openAiShimScript(scriptJson(openAiGlobals(context, view)))

const hostContext = (found: AppTarget, display: AppDisplay): Record<string, unknown> => {
  const displayMode = display.displayMode ?? found.displayMode
  return {
    theme: display.theme,
    displayMode,
    availableDisplayModes: [...new Set([displayMode, ...display.modes])],
    platform: display.platform,
    ...(display.locale === undefined ? {} : { locale: display.locale })
  }
}

const modelContext = (body: ModelContextBody): Record<string, unknown> => ({
  ...(body.content === undefined ? {} : { content: body.content }),
  ...(body.structuredContent === undefined ? {} : { structuredContent: body.structuredContent })
})

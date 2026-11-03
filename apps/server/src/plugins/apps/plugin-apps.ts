import type { CodevisorDatabaseService } from "@codevisor/db"
import type { McpManager } from "@codevisor/mcp"
import type { ReadResourceResult, Tool } from "@modelcontextprotocol/sdk/types.js"

import { HttpFailure, run } from "../../server-context.js"
import { makeAppAudit, type AppAudit, type AppLogSource } from "./plugin-app-audit.js"
import {
  appDocument,
  panePath,
  shellBoot,
  viewPath,
  type AppDisplay,
  type AppTarget,
  type HostInfo,
  type LoadedApp
} from "./plugin-app-boot.js"
import { appPolicy, appSandbox, shellPolicy } from "./plugin-app-csp.js"
import { appShellHtml } from "./plugin-app-shell.js"
import {
  APP_LAUNCH_TTL_MS,
  APP_SESSION_TTL_MS,
  makePluginAppTokens,
  sameScope,
  type PluginAppScope,
  type PluginAppTokens
} from "./plugin-app-tokens.js"
import { hasUiMeta, prefersBorder } from "./plugin-app-ui-meta.js"

export { APP_PROTOCOL_VERSION, type AppDisplay, type AppDisplayMode } from "./plugin-app-boot.js"

export interface AppLaunch {
  readonly url: string
  readonly expiresAt: string
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
  readonly renderFrame: (scope: PluginAppScope, display: AppDisplay) => Promise<RenderedShell>
  readonly callTool: (scope: PluginAppScope, body: ToolCallBody) => Promise<unknown>
  readonly listTools: (scope: PluginAppScope) => Promise<{ tools: ReadonlyArray<Tool> }>
  readonly readResource: (scope: PluginAppScope, uri: string) => Promise<ReadResourceResult>
  readonly saveModelContext: (scope: PluginAppScope, body: ModelContextBody) => Promise<void>
  readonly log: (scope: PluginAppScope, params: Readonly<Record<string, unknown>>) => Promise<void>
}

export interface PluginAppsOptions {
  readonly version: string
  readonly tokens?: PluginAppTokens
  readonly audit?: AppAudit
}

export const makePluginApps = (
  mcp: McpManager,
  db: CodevisorDatabaseService,
  options: PluginAppsOptions
): PluginApps => {
  const tokens = options.tokens ?? makePluginAppTokens()
  const audit = options.audit ?? makeAppAudit()
  const hostInfo: HostInfo = { name: "Codevisor", version: options.version }

  const target = (scope: PluginAppScope): Promise<AppTarget> => {
    if (scope.kind === "view") return viewTarget(mcp, scope.viewId)
    return paneTarget(mcp, scope.serverId, scope.paneType)
  }

  const resourceMeta = async (found: AppTarget, meta: unknown): Promise<unknown> => {
    if (hasUiMeta(meta)) return meta
    const listed = mcp.listedResourceMeta(found.serverId, found.resourceUri, found.accountId)
    return (await listed.catch(() => undefined)) ?? meta
  }

  const instantiatingTool = async (found: AppTarget): Promise<Tool | undefined> => {
    if (found.view === undefined) return undefined
    return mcp.appTool(found.serverId, found.view.toolName)
  }

  const loadApp = async (scope: PluginAppScope, display: AppDisplay): Promise<LoadedApp> => {
    const found = await target(scope)
    const read = await mcp.readResource(found.serverId, found.resourceUri, found.accountId)
    const resource = appResource(found.resourceUri, read)
    const meta = await resourceMeta(found, resource.meta)
    return {
      found,
      html: resource.html,
      sandbox: appSandbox(meta),
      prefersBorder: prefersBorder(meta),
      tool: await instantiatingTool(found),
      display,
      hostInfo
    }
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
      const app = await loadApp(scope, display)
      const session = tokens.issue(scope, APP_SESSION_TTL_MS)
      const boot = shellBoot({ ...app, scope, token: session.token })
      audit.policy(logSource(app.found), appPolicy(app.sandbox.csp))
      return { html: appShellHtml(boot), policy: shellPolicy(app.sandbox.csp) }
    },
    renderFrame: async (scope, display) => {
      const app = await loadApp(scope, display)
      return { html: appDocument(app), policy: appPolicy(app.sandbox.csp) }
    },
    callTool: async (scope, body) => {
      const found = await target(scope)
      return mcp.callAppTool(found.serverId, body.name, { ...body.arguments }, found.accountId)
    },
    listTools: async (scope) => ({ tools: await mcp.listAppTools((await target(scope)).serverId) }),
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
    },
    log: async (scope, params) => {
      audit.message(logSource(await target(scope)), params)
    }
  }
}

interface AppResource {
  readonly html: string
  readonly meta: unknown
}

const logSource = (found: AppTarget): AppLogSource => ({
  serverId: found.serverId,
  resourceUri: found.resourceUri,
  ...(found.view === undefined ? {} : { viewId: found.view.viewId })
})

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

const modelContext = (body: ModelContextBody): Record<string, unknown> => ({
  ...(body.content === undefined ? {} : { content: body.content }),
  ...(body.structuredContent === undefined ? {} : { structuredContent: body.structuredContent })
})

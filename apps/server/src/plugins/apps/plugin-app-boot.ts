import type { PluginAppView } from "@codevisor/mcp"
import type { Tool } from "@modelcontextprotocol/client"

import type { BridgeBoot } from "./plugin-app-bridge.js"
import { appPolicy, frameAllow, type AppSandbox } from "./plugin-app-csp.js"
import { openAiGlobals, openAiShimScript } from "./plugin-app-openai.js"
import { policyMeta, scriptJson, withPreamble } from "./plugin-app-shell.js"
import { contentSizeScript } from "./plugin-app-size.js"
import { appHostStyles, type AppPlatform } from "./plugin-app-styles.js"
import type { PluginAppScope } from "./plugin-app-tokens.js"

export const APP_PROTOCOL_VERSION = "2026-01-26"

export type AppDisplayMode = "inline" | "fullscreen" | "pip"

export interface AppDisplay {
  readonly theme: "light" | "dark"
  readonly displayMode?: AppDisplayMode
  readonly modes: ReadonlyArray<AppDisplayMode>
  readonly platform: AppPlatform
  readonly locale?: string
  readonly maxHeight?: number
}

export interface AppTarget {
  readonly serverId: string
  readonly resourceUri: string
  readonly displayMode: AppDisplayMode
  readonly accountId: string | undefined
  readonly view?: PluginAppView
}

export interface HostInfo {
  readonly name: string
  readonly version: string
}

export interface LoadedApp {
  readonly found: AppTarget
  readonly html: string
  readonly sandbox: AppSandbox
  readonly prefersBorder: boolean | undefined
  readonly tool: Tool | undefined
  readonly display: AppDisplay
  readonly hostInfo: HostInfo
}

export interface ShellParts extends LoadedApp {
  readonly scope: PluginAppScope
  readonly token: string
}

export const viewPath = (viewId: string): string => `/v1/plugins/apps/${encodeURIComponent(viewId)}`

export const panePath = (token: string): string => `/v1/plugins/panes/${token}`

export const appDocument = (app: LoadedApp): string =>
  withPreamble(app.html, appPreamble(app.sandbox, hostContext(app), app.found.view, app.display))

export const shellBoot = (parts: ShellParts): BridgeBoot => {
  const { found, sandbox, display, scope, token } = parts
  return {
    protocolVersion: APP_PROTOCOL_VERSION,
    hostInfo: parts.hostInfo,
    hostCapabilities: hostCapabilities(sandbox),
    hostContext: hostContext(parts),
    html: appDocument(parts),
    allow: frameAllow(sandbox.permissions),
    token,
    framePath: framePath(scope, token),
    ...(display.maxHeight === undefined ? {} : { maxHeight: display.maxHeight }),
    ...(parts.prefersBorder === undefined ? {} : { prefersBorder: parts.prefersBorder }),
    endpoints: endpoints(scope, token),
    ...(found.view === undefined ? {} : viewData(found.view))
  }
}

const deviceCapabilities: Readonly<Record<AppPlatform, { touch: boolean; hover: boolean }>> = {
  desktop: { touch: false, hover: true },
  mobile: { touch: true, hover: false }
}

const hostCapabilities = (sandbox: AppSandbox): Record<string, unknown> => ({
  openLinks: {},
  serverTools: {},
  serverResources: {},
  logging: {},
  message: { text: {} },
  updateModelContext: { text: {}, structuredContent: {} },
  sandbox: { permissions: sandbox.permissions, csp: sandbox.csp }
})

const hostContext = ({ found, display, hostInfo, tool }: LoadedApp): Record<string, unknown> => {
  const displayMode = display.displayMode ?? found.displayMode
  return {
    theme: display.theme,
    displayMode,
    availableDisplayModes: [...new Set([displayMode, ...display.modes])],
    platform: display.platform,
    userAgent: `${hostInfo.name}/${hostInfo.version}`,
    deviceCapabilities: deviceCapabilities[display.platform],
    safeAreaInsets: { top: 0, right: 0, bottom: 0, left: 0 },
    styles: appHostStyles(display.platform),
    ...(tool === undefined ? {} : { toolInfo: { tool } }),
    ...(display.locale === undefined ? {} : { locale: display.locale })
  }
}

const viewData = (view: PluginAppView) => ({
  viewId: view.viewId,
  toolInput: view.toolInput,
  toolResult: view.toolResult
})

const appPreamble = (
  sandbox: AppSandbox,
  context: Readonly<Record<string, unknown>>,
  view: PluginAppView | undefined,
  display: AppDisplay
): string =>
  policyMeta(appPolicy(sandbox.csp)) +
  openAiShimScript(scriptJson(openAiGlobals(context, view, display.maxHeight))) +
  contentSizeScript()

const framePath = (scope: PluginAppScope, token: string): string =>
  scope.kind === "view"
    ? `${viewPath(scope.viewId)}/frame?token=${token}`
    : `${panePath(token)}/frame`

const endpointNames = {
  toolsCall: "tools/call",
  toolsList: "tools/list",
  resourcesRead: "resources/read",
  modelContext: "model-context",
  log: "log"
} as const

const endpoints = (scope: PluginAppScope, token: string): BridgeBoot["endpoints"] => {
  const url = (name: string): string => {
    if (scope.kind === "view") return `${viewPath(scope.viewId)}/${name}?token=${token}`
    return `${panePath(token)}/${name}`
  }
  return {
    toolsCall: url(endpointNames.toolsCall),
    toolsList: url(endpointNames.toolsList),
    resourcesRead: url(endpointNames.resourcesRead),
    modelContext: url(endpointNames.modelContext),
    log: url(endpointNames.log)
  }
}

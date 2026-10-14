import type { IncomingMessage, ServerResponse } from "node:http"
import type { Socket } from "node:net"

import type {
  DiscoverRemotePluginRequest,
  DiscoverRemotePluginResult,
  ImportRemotePluginRequest,
  LinkPluginRequest,
  PluginListResponse,
  PluginPaneTokenRequest,
  PluginPaneTokenResponse,
  PluginRegistryIndex,
  PluginSummary,
  PluginUpdatePlan,
  PluginUpdatesResponse
} from "@codevisor/api"

import type { PluginIconAsset } from "./plugin-icon.js"
import type { ClonePluginSourceResult } from "./plugin-source.js"
import type { PluginSupervisorConfig } from "./plugin-supervisor.js"
import type { PluginToolInvocationContext, PluginToolSummary } from "./plugin-tools.js"

export interface PluginsManagerConfig extends Omit<
  PluginSupervisorConfig,
  "dataDir" | "onStateChange"
> {
  readonly dataDir: string
  readonly pluginsRoot?: string
  readonly platform?: string
  readonly isLocalhost?: (address: string | undefined) => boolean
  readonly clone?: (
    url: string,
    ref: string | undefined,
    destination: string,
    env: NodeJS.ProcessEnv
  ) => Promise<ClonePluginSourceResult>
  readonly codevisorVersion?: string
  readonly fetchPluginRegistry?: () => Promise<PluginRegistryIndex>
}

export interface PluginStateEvent {
  readonly kind: "plugin.state.updated"
  readonly subjectId: string
  readonly payload: PluginSummary
}

export interface PluginsManager {
  readonly startAll: () => Promise<void>
  readonly list: () => Promise<PluginListResponse>
  readonly get: (pluginId: string) => Promise<PluginSummary>
  readonly issuePaneToken: (
    pluginId: string,
    paneId: string,
    request: PluginPaneTokenRequest
  ) => Promise<PluginPaneTokenResponse>
  readonly fetchIcon: (pluginId: string, paneType?: string) => Promise<PluginIconAsset>
  readonly handleProxyRequest: (
    request: IncomingMessage,
    response: ServerResponse,
    url: URL
  ) => Promise<boolean>
  readonly handleUpgrade: (
    request: IncomingMessage,
    socket: Socket,
    head: Buffer
  ) => Promise<boolean>
  readonly restart: (pluginId: string) => Promise<PluginSummary>
  readonly discoverRemote: (
    request: DiscoverRemotePluginRequest
  ) => Promise<DiscoverRemotePluginResult>
  readonly importRemote: (request: ImportRemotePluginRequest) => Promise<PluginSummary>
  readonly listUpdates: () => Promise<PluginUpdatesResponse>
  readonly prepareUpdate: (pluginId: string) => Promise<PluginUpdatePlan>
  readonly applyUpdate: (pluginId: string, planId: string) => Promise<PluginSummary>
  readonly restore: (pluginId: string) => Promise<PluginSummary>
  readonly setEnabled: (pluginId: string, enabled: boolean) => Promise<PluginSummary>
  readonly link: (request: LinkPluginRequest) => Promise<PluginSummary>
  readonly remove: (pluginId: string) => Promise<PluginListResponse>
  readonly unlink: (pluginId: string) => Promise<PluginListResponse>
  readonly subscribe: (listener: (event: PluginStateEvent) => void) => () => void
  readonly listTools: () => Promise<ReadonlyArray<PluginToolSummary>>
  readonly invokeTool: (
    pluginId: string,
    toolName: string,
    args: Readonly<Record<string, unknown>>,
    context?: PluginToolInvocationContext
  ) => Promise<unknown>
  readonly subscribeInstalled: (listener: () => void) => () => void
  readonly close: () => void
}

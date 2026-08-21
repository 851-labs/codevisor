import type {
  DiscoverRemotePluginRequest,
  DiscoverRemotePluginResult,
  ImportRemotePluginRequest,
  LinkPluginRequest,
  PluginListResponse,
  PluginPaneTokenRequest,
  PluginPaneTokenResponse,
  PluginSummary
} from "@codevisor/api"
import type { IncomingMessage, ServerResponse } from "node:http"
import type { Socket } from "node:net"
import type { PluginIconAsset } from "./plugin-icon.js"
import type { PluginSupervisorConfig } from "./plugin-supervisor.js"
import type { PluginToolInvocationContext, PluginToolSummary } from "./plugin-tools.js"

export interface PluginsManagerConfig extends Omit<
  PluginSupervisorConfig,
  "dataDir" | "onStateChange"
> {
  /// Server data dir; per-plugin writable state lives under
  /// `<dataDir>/plugins/<pluginId>`.
  readonly dataDir: string
  readonly pluginsRoot?: string
  /// process.platform override for tests.
  readonly platform?: string
  /// Proxy request timeout before a 504 is returned.
  readonly proxyTimeoutMs?: number
  /// Tool invocation timeout before the call fails as unavailable.
  readonly toolTimeoutMs?: number
  /// Loopback exemption for relayed WebSocket upgrades (the relay cannot
  /// carry cookies on WS channel params); defaults to matching the server's
  /// own loopback auth exemption.
  readonly isLocalhost?: (address: string | undefined) => boolean
  /// Staged-clone override for install tests; defaults to a shallow
  /// `git clone`.
  readonly clone?: (url: string, ref: string | undefined, destination: string) => Promise<void>
}

/// Runtime state transition for one plugin, shaped for the server's event
/// fanout (same contract as HarnessLifecycleEvent).
export interface PluginStateEvent {
  readonly kind: "plugin.state.updated"
  readonly subjectId: string
  readonly payload: PluginSummary
}

export interface PluginsManager {
  /// Starts every compatible installed plugin. Call after the Codevisor HTTP
  /// server begins listening; failures stay isolated to their plugin.
  readonly startAll: () => Promise<void>
  readonly list: () => Promise<PluginListResponse>
  readonly get: (pluginId: string) => Promise<PluginSummary>
  readonly issuePaneToken: (
    pluginId: string,
    paneId: string,
    request: PluginPaneTokenRequest
  ) => Promise<PluginPaneTokenResponse>
  /// Fetches plugin artwork from the supervised loopback process. A pane icon
  /// inherits the plugin-level icon when it has no override.
  readonly fetchIcon: (pluginId: string, paneType?: string) => Promise<PluginIconAsset>
  /// Handles `/v1/plugins/:pluginId/app/*` proxy traffic. Returns false when
  /// the URL is not proxy-shaped so the caller can fall through; runs BEFORE
  /// bearer authorization (pane tokens/cookies are the auth here).
  readonly handleProxyRequest: (
    request: IncomingMessage,
    response: ServerResponse,
    url: URL
  ) => Promise<boolean>
  /// Handles WebSocket upgrades under the proxy prefix. Returns false when
  /// the URL does not target a plugin.
  readonly handleUpgrade: (
    request: IncomingMessage,
    socket: Socket,
    head: Buffer
  ) => Promise<boolean>
  /// Stops and immediately relaunches the plugin, clearing its crash state.
  readonly restart: (pluginId: string) => Promise<PluginSummary>
  /// Stages the source and describes what installing it would run — the
  /// consent step's data. Installs nothing.
  readonly discoverRemote: (
    request: DiscoverRemotePluginRequest
  ) => Promise<DiscoverRemotePluginResult>
  /// Installs (or updates a managed install of) the plugin the source
  /// provides, running its manifest install command.
  readonly importRemote: (request: ImportRemotePluginRequest) => Promise<PluginSummary>
  /// Dev mode: symlink a local plugin directory into the plugins root.
  readonly link: (request: LinkPluginRequest) => Promise<PluginSummary>
  /// Managed-marker-gated uninstall (stops the process first); linked
  /// plugins are refused. Resolves the updated list.
  readonly remove: (pluginId: string) => Promise<PluginListResponse>
  /// Observes runtime state transitions; returns an unsubscribe. Wired into
  /// the server's event fanout as `plugin.state.updated`.
  readonly subscribe: (listener: (event: PluginStateEvent) => void) => () => void
  /// Every agent tool declared by installed plugins, flattened. Feeds the MCP
  /// gateway's `plugin.<pluginId>.<toolName>` catalog.
  readonly listTools: () => Promise<ReadonlyArray<PluginToolSummary>>
  /// Invokes one plugin-declared tool: ensures the plugin is running, POSTs the
  /// JSON arguments to the tool's manifest path with the signed
  /// X-Codevisor-Context headers, and resolves the response body (parsed JSON
  /// when the plugin answers with JSON, otherwise the raw text).
  readonly invokeTool: (
    pluginId: string,
    toolName: string,
    args: Readonly<Record<string, unknown>>,
    context?: PluginToolInvocationContext
  ) => Promise<unknown>
  /// Observes installed-set changes (install, link, update, uninstall) so the
  /// MCP gateway can refresh its advertised plugin tools; returns an
  /// unsubscribe.
  readonly subscribeInstalled: (listener: () => void) => () => void
  readonly close: () => void
}

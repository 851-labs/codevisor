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
import { makePluginInstaller } from "./plugin-install.js"
import {
  makePaneTokenStore,
  PANE_TOKEN_QUERY_PARAM,
  paneCookieHeader,
  paneCookieName,
  readCookieValue,
  stripPaneCookie,
  type PaneTokenScope
} from "./plugin-pane-auth.js"
import { forwardHttp, spliceUpgrade } from "./plugin-proxy.js"
import {
  defaultPluginsRoot,
  findPluginOrFail,
  scanPlugins,
  type InstalledPlugin,
  type PluginScan
} from "./plugin-store.js"
import { makePluginSupervisor, type PluginSupervisorConfig } from "./plugin-supervisor.js"
import { PluginsError } from "./plugins-error.js"

const PROXY_PATH_PATTERN = /^\/v1\/plugins\/([^/]+)\/app(\/.*)?$/

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
  readonly list: () => Promise<PluginListResponse>
  readonly get: (pluginId: string) => Promise<PluginSummary>
  readonly issuePaneToken: (
    pluginId: string,
    paneId: string,
    request: PluginPaneTokenRequest
  ) => Promise<PluginPaneTokenResponse>
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
  /// Stops the plugin's process and clears its crash/circuit-breaker state;
  /// the next pane request relaunches it fresh. Resolves the post-restart
  /// summary.
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
  readonly close: () => void
}

const localhostAddresses = new Set(["127.0.0.1", "::1", "::ffff:127.0.0.1"])

const defaultIsLocalhost = (address: string | undefined): boolean =>
  localhostAddresses.has(String(address))

export const makePluginsManager = (config: PluginsManagerConfig): PluginsManager => {
  const pluginsRoot = config.pluginsRoot ?? defaultPluginsRoot()
  const platform = config.platform ?? process.platform
  const proxyTimeoutMs = config.proxyTimeoutMs ?? 30_000
  const isLoopback = config.isLocalhost ?? defaultIsLocalhost
  const tokens = makePaneTokenStore(config.now)
  const listeners = new Set<(event: PluginStateEvent) => void>()
  /// PluginsManagerConfig is a strict widening of the supervisor's config
  /// (minus dataDir/onStateChange, which the manager owns), so it passes
  /// through wholesale; the supervisor ignores the manager-only keys.
  const supervisorOverrides: Omit<PluginSupervisorConfig, "dataDir" | "onStateChange"> = config
  const supervisor = makePluginSupervisor({
    ...supervisorOverrides,
    // "plugin-data" (not "plugins") so per-plugin runtime state can never
    // collide with an installed-plugins root living in the same directory —
    // dev instances keep both directly under one flat data dir.
    dataDir: `${config.dataDir}/plugin-data`,
    onStateChange: (pluginId) => emitState(pluginId)
  })
  const installer = makePluginInstaller({
    pluginsRoot,
    stop: (pluginId) => supervisor.stop(pluginId),
    ...(config.clone === undefined ? {} : { clone: config.clone }),
    ...(config.registerExternalTerminal === undefined
      ? {}
      : { registerExternalTerminal: config.registerExternalTerminal }),
    ...(config.resolveEnv === undefined ? {} : { resolveEnv: config.resolveEnv }),
    ...(config.spawnShell === undefined ? {} : { spawnShell: config.spawnShell })
  })

  /// A fresh scan per operation keeps "drop a folder in" installs live with
  /// no registration step; the scan is a handful of stats and manifest reads.
  const scan = (): PluginScan => {
    const result = scanPlugins(pluginsRoot)
    return {
      invalid: result.invalid,
      plugins: result.plugins.filter(
        (plugin) =>
          plugin.manifest.platforms === undefined || plugin.manifest.platforms.includes(platform)
      )
    }
  }

  const summarize = (plugin: InstalledPlugin): PluginSummary => ({
    id: plugin.id,
    name: plugin.manifest.name,
    panes: plugin.manifest.panes,
    path: plugin.path,
    source: plugin.source,
    state: supervisor.state(plugin.id),
    version: plugin.manifest.version,
    ...(plugin.manifest.description === undefined
      ? {}
      : { description: plugin.manifest.description })
  })

  /// Fans a supervisor state transition out to subscribers as a full summary.
  /// The transition can arrive asynchronously (crash, idle shutdown), so the
  /// plugin is re-resolved from disk; one uninstalled mid-flight has nothing
  /// left to describe and is skipped.
  const emitState = (pluginId: string): void => {
    const plugin = scan().plugins.find((candidate) => candidate.id === pluginId)
    if (plugin === undefined) {
      return
    }
    const summary = summarize(plugin)
    for (const listener of listeners) {
      listener({ kind: "plugin.state.updated", payload: summary, subjectId: pluginId })
    }
  }

  const contextHeaders = (scope: PaneTokenScope): Record<string, string> => {
    const payload = Buffer.from(
      JSON.stringify({
        cwd: scope.cwd,
        paneId: scope.paneId,
        paneType: scope.paneType,
        pluginId: scope.pluginId,
        themeMode: scope.themeMode,
        workspaceId: scope.workspaceId
      }),
      "utf8"
    ).toString("base64")
    return {
      "x-codevisor-context": payload,
      "x-codevisor-context-signature": tokens.signContext(payload)
    }
  }

  /// Resolves the authenticated pane scope for a proxied request: an initial
  /// `?codevisorPaneToken=` exchange, an established cookie session, or (for
  /// upgrades only) the loopback exemption.
  const authenticate = (
    pluginId: string,
    request: IncomingMessage,
    url: URL
  ): { scope: PaneTokenScope; viaQueryToken: boolean } | undefined => {
    const queryToken = url.searchParams.get(PANE_TOKEN_QUERY_PARAM)
    if (queryToken !== null) {
      const scope = tokens.verify(queryToken, pluginId)
      if (scope !== undefined) {
        tokens.establishSession(queryToken)
        return { scope, viaQueryToken: true }
      }
    }
    const cookieToken = readCookieValue(request.headers.cookie, paneCookieName(pluginId))
    if (cookieToken !== undefined) {
      const scope = tokens.verify(cookieToken, pluginId)
      if (scope !== undefined) {
        return { scope, viaQueryToken: false }
      }
    }
    return undefined
  }

  /// Post-install summary: resolved from the unfiltered store scan so an
  /// install targeting another platform still answers with what landed on
  /// disk instead of a spurious 404.
  const summarizeInstalled = (pluginId: string): PluginSummary => {
    const summary = summarize(findPluginOrFail(scanPlugins(pluginsRoot), pluginId))
    // The list changed: let subscribed clients refresh their chips/cards.
    emitState(pluginId)
    return summary
  }

  return {
    close: () => {
      supervisor.closeAll()
    },
    discoverRemote: async (request) => installer.discoverRemote(request),
    get: async (pluginId) => summarize(findPluginOrFail(scan(), pluginId)),
    importRemote: async (request) => {
      const manifest = await installer.importRemote(request)
      return summarizeInstalled(manifest.id)
    },
    link: async (request) => {
      const manifest = await installer.link(request)
      return summarizeInstalled(manifest.id)
    },
    remove: async (pluginId) => {
      // The supervisor stop inside the installer emits any final state
      // transition while the plugin still resolves on disk; after deletion
      // there is nothing left to describe, so the list response is the
      // client's refresh signal.
      await installer.remove(pluginId)
      return { plugins: scan().plugins.map(summarize) }
    },
    handleProxyRequest: async (request, response, url) => {
      const match = PROXY_PATH_PATTERN.exec(url.pathname)
      if (match === null) {
        return false
      }
      /* v8 ignore next -- the pattern's first capture always exists on match. */
      const pluginId = decodeURIComponent(match[1] ?? "")
      const subPath = match[2]
      // `/app` without the trailing slash would make every relative URL in
      // the pane document resolve outside the proxy prefix; redirect once
      // rather than serving a subtly broken document.
      if (subPath === undefined) {
        response.writeHead(308, { Location: `/v1/plugins/${pluginId}/app/${url.search}` })
        response.end()
        return true
      }
      const plugin = findPluginOrFail(scan(), pluginId)
      const authenticated = authenticate(pluginId, request, url)
      if (authenticated === undefined) {
        throw new PluginsError("notFound", "Pane session is missing or expired")
      }
      const port = await supervisor.ensureRunning(plugin)
      const forwardedQuery = new URLSearchParams(url.searchParams)
      forwardedQuery.delete(PANE_TOKEN_QUERY_PARAM)
      const query = forwardedQuery.toString()
      const outcome = await forwardHttp({
        contextHeaders: contextHeaders(authenticated.scope),
        cookieHeader: stripPaneCookie(request.headers.cookie, paneCookieName(pluginId)),
        port,
        request,
        response,
        targetPath: query.length === 0 ? subPath : `${subPath}?${query}`,
        timeoutMs: proxyTimeoutMs,
        ...(authenticated.viaQueryToken
          ? {
              setCookie: paneCookieHeader(
                pluginId,
                /* v8 ignore next -- viaQueryToken implies the query param exists. */
                url.searchParams.get(PANE_TOKEN_QUERY_PARAM) ?? ""
              )
            }
          : {})
      })
      if (outcome === "ok") {
        supervisor.noteSuccess(plugin.id)
      } else if (outcome === "unreachable") {
        // The port is dead even though the runtime looked alive: kick the
        // supervisor so the NEXT request relaunches instead of forwarding
        // into a dead port forever.
        supervisor.markUnreachable(plugin.id)
      }
      return true
    },
    handleUpgrade: async (request, socket, head) => {
      /* v8 ignore next -- Node HTTP upgrade requests always carry a URL. */
      const url = new URL(request.url ?? "/", "http://127.0.0.1")
      const match = PROXY_PATH_PATTERN.exec(url.pathname)
      if (match === null) {
        return false
      }
      try {
        /* v8 ignore next -- the pattern's first capture always exists on match. */
        const pluginId = decodeURIComponent(match[1] ?? "")
        const subPath = match[2] ?? "/"
        const plugin = findPluginOrFail(scan(), pluginId)
        // Relay WS channels carry only a path — no cookies — and always
        // arrive from the in-process loopback bridge, so loopback is an
        // accepted principal exactly like the server's own auth exemption.
        const authenticated = authenticate(pluginId, request, url)
        if (authenticated === undefined && !isLoopback(request.socket.remoteAddress)) {
          socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n")
          socket.destroy()
          return true
        }
        const port = await supervisor.ensureRunning(plugin)
        const forwardedQuery = new URLSearchParams(url.searchParams)
        forwardedQuery.delete(PANE_TOKEN_QUERY_PARAM)
        const query = forwardedQuery.toString()
        // An open splice pins the process alive; the idle clock resumes when
        // the socket closes (spliceUpgrade reports it exactly once).
        const release = supervisor.pin(plugin.id)
        spliceUpgrade({
          contextHeaders: authenticated === undefined ? {} : contextHeaders(authenticated.scope),
          head,
          onClose: release,
          port,
          request,
          socket,
          targetPath: query.length === 0 ? subPath : `${subPath}?${query}`
        })
      } catch {
        socket.write("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
        socket.destroy()
      }
      return true
    },
    issuePaneToken: async (pluginId, paneId, tokenRequest) => {
      const plugin = findPluginOrFail(scan(), pluginId)
      const pane = plugin.manifest.panes.find(
        (candidate) => candidate.type === tokenRequest.paneType
      )
      if (pane === undefined) {
        throw new PluginsError(
          "notFound",
          `Plugin ${pluginId} has no pane type: ${tokenRequest.paneType}`
        )
      }
      const issued = tokens.issue({
        paneId,
        paneType: pane.type,
        pluginId,
        ...(tokenRequest.cwd === undefined ? {} : { cwd: tokenRequest.cwd }),
        ...(tokenRequest.themeMode === undefined ? {} : { themeMode: tokenRequest.themeMode }),
        ...(tokenRequest.workspaceId === undefined ? {} : { workspaceId: tokenRequest.workspaceId })
      })
      const query = new URLSearchParams({
        paneId,
        [PANE_TOKEN_QUERY_PARAM]: issued.token
      })
      return {
        expiresAt: issued.expiresAt,
        path: `/v1/plugins/${pluginId}/app${pane.path}?${query.toString()}`,
        token: issued.token
      }
    },
    list: async () => ({ plugins: scan().plugins.map(summarize) }),
    restart: async (pluginId) => {
      const plugin = findPluginOrFail(scan(), pluginId)
      supervisor.restart(pluginId)
      return summarize(plugin)
    },
    subscribe: (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    }
  }
}

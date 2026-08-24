import type { PluginSummary } from "@codevisor/api"
import type { IncomingMessage } from "node:http"
import { makePluginInstaller } from "./plugin-install.js"
import { fetchPluginIcon } from "./plugin-icon.js"
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
import type {
  PluginsManager,
  PluginsManagerConfig,
  PluginStateEvent
} from "./plugins-manager-types.js"
import { invokePluginTool } from "./plugin-tools.js"
import { PluginsError } from "./plugins-error.js"

export type { PluginToolInvocationContext, PluginToolSummary } from "./plugin-tools.js"
export type {
  PluginsManager,
  PluginsManagerConfig,
  PluginStateEvent
} from "./plugins-manager-types.js"

const PROXY_PATH_PATTERN = /^\/v1\/plugins\/([^/]+)\/app(\/.*)?$/

const localhostAddresses = new Set(["127.0.0.1", "::1", "::ffff:127.0.0.1"])

const defaultIsLocalhost = (address: string | undefined): boolean =>
  localhostAddresses.has(String(address))

export const makePluginsManager = (config: PluginsManagerConfig): PluginsManager => {
  const pluginsRoot = config.pluginsRoot ?? defaultPluginsRoot()
  const platform = config.platform ?? process.platform
  const proxyTimeoutMs = config.proxyTimeoutMs ?? 30_000
  const toolTimeoutMs = config.toolTimeoutMs ?? 30_000
  const isLoopback = config.isLocalhost ?? defaultIsLocalhost
  const tokens = makePaneTokenStore(config.now)
  const listeners = new Set<(event: PluginStateEvent) => void>()
  const installedListeners = new Set<() => void>()
  const maintaining = new Set<string>()
  let isClosing = false
  /* v8 ignore next -- replaced before the supervisor can invoke it. */
  let requestMaintenance: (pluginId: string) => void = () => undefined
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
    onStateChange: (pluginId) => emitState(pluginId),
    onUnexpectedExit: (pluginId) => requestMaintenance(pluginId)
  })
  const installer = makePluginInstaller({
    pluginsRoot,
    stop: (pluginId) => supervisor.stop(pluginId),
    ...(config.clone === undefined ? {} : { clone: config.clone }),
    ...(config.registerExternalTerminal === undefined
      ? {}
      : { registerExternalTerminal: config.registerExternalTerminal }),
    ...(config.resolveEnv === undefined ? {} : { resolveEnv: config.resolveEnv }),
    ...(config.spawnShell === undefined ? {} : { spawnShell: config.spawnShell }),
    ...(config.spawnArgv === undefined ? {} : { spawnArgv: config.spawnArgv }),
    ...(config.codevisorVersion === undefined ? {} : { codevisorVersion: config.codevisorVersion }),
    platform
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
      : { description: plugin.manifest.description }),
    ...(plugin.manifest.iconPath === undefined ? {} : { iconPath: plugin.manifest.iconPath }),
    ...(plugin.manifest.tools === undefined ? {} : { tools: plugin.manifest.tools })
  })

  /// Fans a supervisor state transition out to subscribers as a full summary.
  /// The transition can arrive asynchronously (for example, after a crash), so the
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

  /// Encodes and signs a context payload so plugins can trust that
  /// X-Codevisor-Context came from this server — shared by pane proxying and
  /// tool invocation, which carry different context shapes.
  const signedContextHeaders = (
    payload: Readonly<Record<string, unknown>>
  ): Record<string, string> => {
    const encoded = Buffer.from(JSON.stringify(payload), "utf8").toString("base64")
    return {
      "x-codevisor-context": encoded,
      "x-codevisor-context-signature": tokens.signContext(encoded)
    }
  }

  const contextHeaders = (scope: PaneTokenScope): Record<string, string> =>
    signedContextHeaders({
      cwd: scope.cwd,
      paneId: scope.paneId,
      paneType: scope.paneType,
      pluginId: scope.pluginId,
      themeMode: scope.themeMode,
      workspaceId: scope.workspaceId
    })

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

  /// The installed set changed (install, update, link, uninstall): let the
  /// MCP gateway refresh which plugin tools it advertises to agents.
  const notifyInstalled = (): void => {
    for (const listener of installedListeners) {
      listener()
    }
  }

  /// Restore the invariant that every compatible installed plugin is
  /// running. The supervisor owns exponential backoff and the circuit
  /// breaker; this loop merely retries after each gate until the plugin runs,
  /// becomes terminally failed, is uninstalled, or the server closes.
  const maintain = async (pluginId: string): Promise<void> => {
    if (maintaining.has(pluginId) || isClosing) {
      return
    }
    maintaining.add(pluginId)
    try {
      while (!isClosing) {
        const plugin = scan().plugins.find((candidate) => candidate.id === pluginId)
        if (plugin === undefined || supervisor.state(pluginId) === "failed") {
          return
        }
        try {
          await supervisor.ensureRunning(plugin)
          return
        } catch {
          if (supervisor.state(pluginId) === "failed") {
            return
          }
          await new Promise((resolve) => setTimeout(resolve, 500))
        }
      }
    } finally {
      maintaining.delete(pluginId)
    }
  }
  requestMaintenance = (pluginId) => {
    void maintain(pluginId)
  }

  /// Post-install summary: resolved from the unfiltered store scan so an
  /// install targeting another platform still answers with what landed on
  /// disk instead of a spurious 404.
  const summarizeInstalled = async (pluginId: string): Promise<PluginSummary> => {
    const installed = findPluginOrFail(scanPlugins(pluginsRoot), pluginId)
    const compatible = scan().plugins.find((plugin) => plugin.id === pluginId)
    if (compatible !== undefined) {
      try {
        await supervisor.ensureRunning(compatible)
      } catch {
        requestMaintenance(pluginId)
      }
    }
    const summary = summarize(installed)
    // The list changed: let subscribed clients refresh their chips/cards.
    emitState(pluginId)
    notifyInstalled()
    return summary
  }

  return {
    close: () => {
      isClosing = true
      supervisor.closeAll()
    },
    discoverRemote: async (request) => installer.discoverRemote(request),
    get: async (pluginId) => summarize(findPluginOrFail(scan(), pluginId)),
    fetchIcon: async (pluginId, paneType) => {
      const plugin = findPluginOrFail(scan(), pluginId)
      return fetchPluginIcon({
        ensureRunning: () => supervisor.ensureRunning(plugin),
        markUnreachable: () => supervisor.markUnreachable(plugin.id),
        noteSuccess: () => supervisor.noteSuccess(plugin.id),
        paneType,
        plugin,
        signedContextHeaders,
        timeoutMs: proxyTimeoutMs
      })
    },
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
      notifyInstalled()
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
        // supervisor so automatic maintenance relaunches it.
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
        // Remote plugin sockets arrive through the restricted relay byte
        // tunnel as a loopback connection, so loopback is an accepted
        // principal exactly like the server's own auth exemption.
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
        spliceUpgrade({
          contextHeaders: authenticated === undefined ? {} : contextHeaders(authenticated.scope),
          head,
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
    invokeTool: async (pluginId, toolName, args, context = {}) => {
      const plugin = findPluginOrFail(scan(), pluginId)
      return invokePluginTool({
        args,
        context,
        ensureRunning: () => supervisor.ensureRunning(plugin),
        markUnreachable: () => supervisor.markUnreachable(plugin.id),
        noteSuccess: () => supervisor.noteSuccess(plugin.id),
        plugin,
        signedContextHeaders,
        timeoutMs: toolTimeoutMs,
        toolName
      })
    },
    list: async () => ({ plugins: scan().plugins.map(summarize) }),
    listTools: async () =>
      scan().plugins.flatMap((plugin) =>
        (plugin.manifest.tools ?? []).map((tool) => ({
          description: tool.description,
          name: tool.name,
          pluginId: plugin.id,
          ...(tool.inputSchema === undefined ? {} : { inputSchema: tool.inputSchema })
        }))
      ),
    restart: async (pluginId) => {
      const plugin = findPluginOrFail(scan(), pluginId)
      supervisor.restart(pluginId)
      await supervisor.ensureRunning(plugin)
      return summarize(plugin)
    },
    startAll: async () => {
      await Promise.all(scan().plugins.map(async (plugin) => maintain(plugin.id)))
    },
    subscribe: (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
    subscribeInstalled: (listener) => {
      installedListeners.add(listener)
      return () => installedListeners.delete(listener)
    }
  }
}

import type { PluginSummary } from "@codevisor/api"

import { makePluginEnabledState } from "./plugin-enabled-state.js"
import { fetchPluginIcon } from "./plugin-icon.js"
import { makePluginInstaller } from "./plugin-install.js"
import { makePluginMaintenance } from "./plugin-maintenance.js"
import {
  issuePluginPaneToken,
  makePaneAuthenticator,
  makePaneContextHeaders,
  makePaneTokenStore,
  makeSignedContextHeaders,
  PANE_TOKEN_QUERY_PARAM,
  paneCookieHeader,
  paneCookieName,
  stripPaneCookie
} from "./plugin-pane-auth.js"
import { forwardHttp, spliceUpgrade } from "./plugin-proxy.js"
import { makePluginRequestLease } from "./plugin-request-lease.js"
import {
  defaultPluginsRoot,
  findPluginOrFail,
  scanPlugins,
  type InstalledPlugin,
  type PluginScan
} from "./plugin-store.js"
import { summarizePlugin } from "./plugin-summary.js"
import { makePluginSupervisor, type PluginSupervisorConfig } from "./plugin-supervisor.js"
import { invokePluginTool } from "./plugin-tools.js"
import { makePluginUpdates } from "./plugin-updates.js"
import { PluginsError } from "./plugins-error.js"
import type {
  PluginsManager,
  PluginsManagerConfig,
  PluginStateEvent
} from "./plugins-manager-types.js"

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

const PROXY_TIMEOUT_MS = 30_000
const TOOL_TIMEOUT_MS = 30_000

export const makePluginsManager = (config: PluginsManagerConfig): PluginsManager => {
  const pluginsRoot = config.pluginsRoot ?? defaultPluginsRoot()
  const platform = config.platform ?? process.platform
  const isLoopback = config.isLocalhost ?? defaultIsLocalhost
  const pluginDataRoot = `${config.dataDir}/plugin-data`
  const { assertEnabled, isEnabled, persist } = makePluginEnabledState(pluginDataRoot)
  const tokens = makePaneTokenStore(config.now)
  const listeners = new Set<(event: PluginStateEvent) => void>()
  const installedListeners = new Set<() => void>()
  let isClosing = false
  const supervisorOverrides: Omit<PluginSupervisorConfig, "dataDir" | "onStateChange"> = config
  const supervisor = makePluginSupervisor({
    ...supervisorOverrides,
    contextSecret: tokens.contextSecret,
    dataDir: pluginDataRoot,
    onStateChange: (pluginId) => emitState(pluginId),
    onUnexpectedExit: (pluginId) => requestMaintenance(pluginId)
  })
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

  const { maintain, request: requestMaintenance } = makePluginMaintenance({
    isClosing: () => isClosing,
    isEnabled,
    log: config.log,
    scan,
    sleep: config.sleep,
    supervisor
  })

  const installer = makePluginInstaller({
    pluginDataRoot,
    pluginsRoot,
    stop: (pluginId) => supervisor.stop(pluginId),
    verifyInstalled: async (pluginId) => {
      await supervisor.ensureRunning(findPluginOrFail(scan(), pluginId))
      if (!isEnabled(pluginId)) supervisor.stop(pluginId)
    },
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
  const updates = makePluginUpdates({
    installer,
    listInstalled: () => scanPlugins(pluginsRoot).plugins,
    platform,
    ...(config.codevisorVersion === undefined ? {} : { codevisorVersion: config.codevisorVersion }),
    ...(config.fetchPluginRegistry === undefined
      ? {}
      : { fetchRegistry: config.fetchPluginRegistry }),
    ...(config.now === undefined ? {} : { now: config.now })
  })

  const summarize = (plugin: InstalledPlugin): PluginSummary =>
    summarizePlugin(plugin, {
      canRestore: installer.canRestore(plugin.id),
      enabled: isEnabled(plugin.id),
      state: supervisor.state(plugin.id)
    })

  const emitState = (pluginId: string): void => {
    let plugin: InstalledPlugin | undefined
    try {
      plugin = scan().plugins.find((candidate) => candidate.id === pluginId)
    } catch (cause) {
      config.log?.(`Plugin ${pluginId} state not published: ${String(cause)}`)
      return
    }
    if (plugin === undefined) {
      return
    }
    const summary = summarize(plugin)
    for (const listener of listeners) {
      listener({ kind: "plugin.state.updated", payload: summary, subjectId: pluginId })
    }
  }

  const signedContextHeaders = makeSignedContextHeaders(tokens)
  const contextHeaders = makePaneContextHeaders(signedContextHeaders)
  const authenticate = makePaneAuthenticator(tokens)

  const notifyInstalled = (): void => {
    for (const listener of installedListeners) {
      listener()
    }
  }

  const summarizeInstalled = async (pluginId: string): Promise<PluginSummary> => {
    const installed = findPluginOrFail(scanPlugins(pluginsRoot), pluginId)
    const compatible = scan().plugins.find((plugin) => plugin.id === pluginId)
    if (compatible !== undefined && isEnabled(pluginId)) {
      try {
        await supervisor.ensureRunning(compatible)
      } catch {
        requestMaintenance(pluginId)
      }
    }
    const summary = summarize(installed)
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
      assertEnabled(pluginId)
      return fetchPluginIcon({
        ...makePluginRequestLease(supervisor, plugin),
        paneType,
        plugin,
        signedContextHeaders: signedContextHeaders(plugin.id),
        timeoutMs: PROXY_TIMEOUT_MS
      })
    },
    importRemote: async (request) => {
      const manifest = await installer.importRemote(request)
      return summarizeInstalled(manifest.id)
    },
    listUpdates: updates.list,
    prepareUpdate: updates.prepare,
    applyUpdate: async (pluginId, planId) => {
      const manifest = await updates.apply(pluginId, planId)
      return summarizeInstalled(manifest.id)
    },
    restore: async (pluginId) => {
      const manifest = await installer.restore(pluginId)
      return summarizeInstalled(manifest.id)
    },
    link: async (request) => {
      const manifest = await installer.link(request)
      return summarizeInstalled(manifest.id)
    },
    unlink: async (pluginId) => {
      await installer.unlink(pluginId)
      await persist(pluginId, true)
      notifyInstalled()
      return { plugins: scan().plugins.map(summarize) }
    },
    remove: async (pluginId) => {
      await installer.remove(pluginId)
      await persist(pluginId, true)
      notifyInstalled()
      return { plugins: scan().plugins.map(summarize) }
    },
    handleProxyRequest: async (request, response, url) => {
      const match = PROXY_PATH_PATTERN.exec(url.pathname)
      if (match === null) {
        return false
      }
      /* v8 ignore next */
      const pluginId = decodeURIComponent(match[1] ?? "")
      const subPath = match[2]
      if (subPath === undefined) {
        response.writeHead(308, { Location: `/v1/plugins/${pluginId}/app/${url.search}` })
        response.end()
        return true
      }
      const plugin = findPluginOrFail(scan(), pluginId)
      assertEnabled(pluginId)
      const authenticated = authenticate(pluginId, request, url)
      if (authenticated === undefined) {
        throw new PluginsError("notFound", "Pane session is missing or expired")
      }
      const lease = await supervisor.acquire(plugin)
      const port = lease.port
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
        timeoutMs: PROXY_TIMEOUT_MS,
        ...(authenticated.viaQueryToken
          ? {
              setCookie: paneCookieHeader(
                pluginId,
                /* v8 ignore next */
                url.searchParams.get(PANE_TOKEN_QUERY_PARAM) ?? ""
              )
            }
          : {})
      })
      if (outcome === "ok") {
        supervisor.noteSuccess(plugin.id, lease)
      } else if (outcome === "unreachable") {
        supervisor.markUnreachable(plugin.id, lease)
      }
      return true
    },
    handleUpgrade: async (request, socket, head) => {
      /* v8 ignore next */
      const url = new URL(request.url ?? "/", "http://127.0.0.1")
      const match = PROXY_PATH_PATTERN.exec(url.pathname)
      if (match === null) {
        return false
      }
      try {
        /* v8 ignore next */
        const pluginId = decodeURIComponent(match[1] ?? "")
        const subPath = match[2] ?? "/"
        const plugin = findPluginOrFail(scan(), pluginId)
        assertEnabled(pluginId)
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
      assertEnabled(pluginId)
      return issuePluginPaneToken(tokens, plugin, pluginId, paneId, tokenRequest)
    },
    invokeTool: async (pluginId, toolName, args, context = {}) => {
      const plugin = findPluginOrFail(scan(), pluginId)
      assertEnabled(pluginId)
      return invokePluginTool({
        args,
        context,
        ...makePluginRequestLease(supervisor, plugin),
        plugin,
        signedContextHeaders: signedContextHeaders(plugin.id),
        timeoutMs: TOOL_TIMEOUT_MS,
        toolName
      })
    },
    list: async () => ({ plugins: scan().plugins.map(summarize) }),
    listTools: async () =>
      scan().plugins.flatMap((plugin) =>
        !isEnabled(plugin.id)
          ? []
          : (plugin.manifest.tools ?? []).map((tool) => ({
              description: tool.description,
              name: tool.name,
              pluginId: plugin.id,
              ...(tool.inputSchema === undefined ? {} : { inputSchema: tool.inputSchema })
            }))
      ),
    restart: async (pluginId) => {
      const plugin = findPluginOrFail(scan(), pluginId)
      assertEnabled(pluginId)
      supervisor.restart(pluginId)
      await supervisor.ensureRunning(plugin)
      return summarize(plugin)
    },
    setEnabled: async (pluginId, enabled) => {
      const plugin = findPluginOrFail(scan(), pluginId)
      await persist(pluginId, enabled)
      if (enabled) {
        try {
          await supervisor.ensureRunning(plugin)
        } catch {
          requestMaintenance(pluginId)
        }
      } else {
        supervisor.stop(pluginId)
      }
      emitState(pluginId)
      notifyInstalled()
      return summarize(plugin)
    },
    startAll: async () => {
      await installer.recover()
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

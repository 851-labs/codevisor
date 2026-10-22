import { existsSync, mkdirSync } from "node:fs"
import { join } from "node:path"

import type { CodevisorDatabaseService } from "@codevisor/db"

import type { AutomationProviderContext } from "./automation-provider.js"
import { textToolResult } from "./automation-provider.js"
import { discardTargetState, jsonResult, type BrowserRuntime } from "./browser-cdp-engine.js"
import { CdpConnection } from "./browser-cdp.js"
import {
  downloadedChromiumPath,
  runBrowserInstaller,
  systemChromePath,
  userChromiumIsRunning
} from "./browser-chromium.js"
import {
  browserExtensionArchivePath,
  browserExtensionInstallation,
  chromeBrowserAvailable,
  makeBrowserExtensionRelay,
  openBrowserExtensionDevelopmentFolder,
  openBrowserExtensionDevelopmentInstaller,
  openBrowserExtensionDevelopmentPage,
  openBrowserExtensionWebStore,
  prepareBrowserExtension,
  type BrowserExtensionInstallation
} from "./browser-extension-relay.js"
import { extensionNeedsUpdate } from "./browser-extension-update.js"
import { makeBrowserHostRegistry, type BrowserHostRegistry } from "./browser-host-registry.js"
import { makeBrowserPreviews } from "./browser-preview.js"
import { makeBrowserRepls, browserResultValue } from "./browser-repl.js"
import { makeBrowserRuntimeFactory } from "./browser-runtime-factory.js"
import { serializedBrowserOperation, closeBrowserRuntime } from "./browser-runtime-lifecycle.js"
import { finishSessionTabs, trackPopups } from "./browser-tab-cleanup.js"
import {
  makeBrowserToolInvoker,
  runtimeKey,
  type BrowserAssetInventory
} from "./browser-use-invoke.js"
import {
  browserExtensionState,
  browserStatusReport,
  chromeNotConnectedResult,
  builtinLostResult,
  noBrowserSelectedResult,
  type BuiltinBrowserState
} from "./browser-use-status.js"
import { browserUseTools } from "./browser-use-tools.js"

export { browserUseTools } from "./browser-use-tools.js"

export type {
  BrowserBackend,
  BrowserClientPlatform,
  BrowserUseProvider
} from "./browser-use-provider-types.js"
import type {
  BrowserBackend,
  BrowserClientPlatform,
  BrowserExtensionSetupMode,
  BrowserUseProvider
} from "./browser-use-provider-types.js"

const extensionEndpoint = (): string | undefined => process.env.CODEVISOR_BROWSER_CDP_URL

const chromiumBackend = (browsersDir: string): string => {
  if (systemChromePath() !== undefined) return "systemChrome"
  if (downloadedChromiumPath(browsersDir) !== undefined) return "downloadedChromium"
  return "missing"
}

export const makeBrowserUseProvider = (
  dataDir: string,
  serverBaseUrl: string,
  db?: CodevisorDatabaseService,
  hosts: BrowserHostRegistry = makeBrowserHostRegistry()
): BrowserUseProvider => {
  const repls = makeBrowserRepls()
  const contexts = new Map<string, AutomationProviderContext>()
  const browsersDir = join(dataDir, "browser", "browsers")
  const profilesDir = join(dataDir, "browser", "profiles")
  const downloadsDir = join(dataDir, "browser", "downloads")
  const assetsDir = join(dataDir, "browser", "assets")
  mkdirSync(browsersDir, { recursive: true, mode: 0o700 })
  mkdirSync(profilesDir, { recursive: true, mode: 0o700 })
  mkdirSync(downloadsDir, { recursive: true, mode: 0o700 })
  mkdirSync(assetsDir, { recursive: true, mode: 0o700 })
  const fallbackReasons = new Map<string, string>()
  const retiredRuntimes = new Set<BrowserRuntime>()
  const runtimes = new Map<string, Promise<BrowserRuntime>>()
  const sessionBackends = new Map<string, BrowserBackend>()
  const clientPlatforms = new Map<string, BrowserClientPlatform>()
  const selectedTargets = new Map<string, string>()
  const sessionTargets = new Map<string, Map<string, "created" | "claimed">>()
  const sessionDispositions = new Map<string, Map<string, "deliverable" | "handoff">>()
  const assetInventories = new Map<string, BrowserAssetInventory>()
  const extensionRelay = makeBrowserExtensionRelay()
  const previews = makeBrowserPreviews()
  const developmentExtensionPath = prepareBrowserExtension(dataDir, serverBaseUrl)
  let relayBaseUrl = serverBaseUrl
  const extensionArchive = browserExtensionArchivePath(developmentExtensionPath)
  const extensionSetupMode: BrowserExtensionSetupMode =
    process.env.CODEVISOR_DEV_WORKTREE !== undefined ||
    process.env.HERDMAN_DEV_WORKTREE !== undefined
      ? "development"
      : "webStore"
  const stopRelayLifecycle = extensionRelay.onConnectionChange((connected) => {
    if (!connected) runtimes.delete("extension")
  })
  let setupPromise: Promise<void> | undefined
  let setupError: string | undefined

  const status = () => {
    const extension = browserExtensionInstallation()
    return {
      engine: "codevisor-cdp",
      backend: chromiumBackend(browsersDir),
      extensionAvailable: extension.bundled,
      extensionInstalled: extension.installed,
      extensionInstallationState: extension.installationState,
      extensionConnected: extensionConnected(),
      extensionNeedsUpdate: updateRequired(extension),
      extensionSetupMode,
      chromeAvailable: chromeBrowserAvailable(),
      developmentExtensionPath,
      extensionArchivePath: extensionArchive,
      userBrowserOpen: userChromiumIsRunning(),
      installing: setupPromise !== undefined,
      ...(setupError === undefined ? {} : { error: setupError })
    }
  }

  const ensureSetup = async (): Promise<void> => {
    if (systemChromePath() !== undefined || downloadedChromiumPath(browsersDir) !== undefined)
      return
    if (setupPromise !== undefined) return setupPromise
    setupError = undefined
    setupPromise = runBrowserInstaller(browsersDir)
      .catch((cause) => {
        setupError = cause instanceof Error ? cause.message : String(cause)
        throw cause
      })
      .finally(() => {
        setupPromise = undefined
      })
    return setupPromise
  }

  const createRuntime = makeBrowserRuntimeFactory({
    db,
    profilesDir,
    browsersDir,
    downloadsDir,
    fallbackReasons,
    ensureSetup,
    connectNative: hosts.connect,
    connectExtension: () => {
      const endpoint = extensionEndpoint()
      if (endpoint === undefined) return extensionRelay.connect()
      return CdpConnection.connect(endpoint)
    }
  })

  const runtime = (
    context: AutomationProviderContext,
    backend: BrowserBackend
  ): Promise<BrowserRuntime> => {
    const key = runtimeKey(context, backend)
    const existing = runtimes.get(key)
    if (existing !== undefined) {
      return existing.then((active) => {
        if (active.native || !active.connection.closed || runtimes.get(key) !== existing)
          return active
        runtimes.delete(key)
        return runtime(context, backend)
      })
    }
    const created = createRuntime(context, backend)
      .then((active) => {
        if (!active) throw new Error("Browser initialization did not produce a connection")
        trackPopups(sessionTargets, key, active)
        return active
      })
      .catch((cause) => {
        runtimes.delete(key)
        throw cause
      })
    runtimes.set(key, created)
    return created
  }

  const extensionConnected = () => extensionEndpoint() !== undefined || extensionRelay.connected()

  const builtinState = (context: AutomationProviderContext): BuiltinBrowserState => {
    const { host, lostHost } = hosts.state(context.sessionId)
    const fallback = fallbackReasons.get(context.sessionId)
    return {
      ready: fallback === undefined && host !== undefined,
      ...(host === undefined ? {} : { host: host.name }),
      ...(lostHost === undefined ? {} : { lostHost }),
      ...(fallback === undefined && host !== undefined
        ? {}
        : { reason: fallback ?? "No Codevisor Mac app is connected to this server." })
    }
  }

  const dropNativeRuntime = async (context: AutomationProviderContext, active: BrowserRuntime) => {
    const key = runtimeKey(context, "builtin")
    if (runtimes.has(key)) runtimes.delete(key)
    for (const dispose of active.eventDisposers) dispose()
    await active.connection.close()
    const handles = `${key}:${context.sessionId}`
    selectedTargets.delete(handles)
    sessionTargets.delete(handles)
    sessionDispositions.delete(handles)
    await repls.reset(context.sessionId)
    return builtinLostResult(hosts.state(context.sessionId))
  }

  const browserStatus = async (context: AutomationProviderContext) =>
    browserStatusReport({
      selected: sessionBackends.get(context.sessionId),
      platform: clientPlatforms.get(context.sessionId),
      managedError: setupError,
      builtin: builtinState(context),
      extension: extensionReport(browserExtensionInstallation())
    })

  const extensionReport = (installation: BrowserExtensionInstallation) =>
    browserExtensionState({
      connected: extensionConnected(),
      chromeAvailable: chromeBrowserAvailable(),
      installationState: installation.installationState,
      needsUpdate: updateRequired(installation)
    })

  const updateRequired = (installation: BrowserExtensionInstallation): boolean =>
    extensionNeedsUpdate({
      connected: extensionConnected(),
      relayBaseUrl,
      profiles: installation.profiles
    })

  const discardSessionHandles = async (sessionId: string) => {
    await repls.reset(sessionId)
    const suffix = `:${sessionId}`
    for (const map of [selectedTargets, sessionTargets, sessionDispositions]) {
      for (const key of map.keys()) if (key.endsWith(suffix)) map.delete(key)
    }
  }

  const invokeTool = makeBrowserToolInvoker({
    assetInventories,
    assetsDir,
    downloadsDir,
    selectedTargets,
    sessionBackends,
    sessionDispositions,
    sessionTargets
  })

  const provider: BrowserUseProvider = {
    id: "browser",
    tools: browserUseTools,
    ensureSetup,
    status,
    sessionBackend: (sessionId) => sessionBackends.get(sessionId),
    setSessionBackend: (sessionId, backend) => sessionBackends.set(sessionId, backend),
    beginTurn: async (sessionId, options) => {
      if (options?.clientPlatform === undefined) clientPlatforms.delete(sessionId)
      else clientPlatforms.set(sessionId, options.clientPlatform)
      const context = contexts.get(sessionId)
      if (context === undefined || sessionBackends.get(sessionId) !== "builtin") return
      const key = runtimeKey(context, "builtin")
      const current = await runtimes.get(key)?.catch(() => undefined)
      let changed = !current && fallbackReasons.has(sessionId)
      fallbackReasons.delete(sessionId)
      if (current && (!current.native || current.connection.closed)) {
        const native = await createRuntime(context, "builtin", true)
        if (native || current.connection.closed) {
          runtimes.delete(key)
          retiredRuntimes.add(current)
          if (native) runtimes.set(key, Promise.resolve(native))
          changed = true
        }
      }
      if (changed) await discardSessionHandles(sessionId)
    },
    acceptBrowserHost: hosts.accept,
    acceptExtensionConnection: (socket) => {
      runtimes.delete("extension")
      extensionRelay.accept(socket)
    },
    onExtensionConnectionChange: extensionRelay.onConnectionChange,
    openDevelopmentExtensionFolder: () =>
      openBrowserExtensionDevelopmentFolder(developmentExtensionPath),
    openDevelopmentExtensionPage: () =>
      openBrowserExtensionDevelopmentPage(developmentExtensionPath),
    openDevelopmentExtensionInstaller: () =>
      openBrowserExtensionDevelopmentInstaller(developmentExtensionPath),
    openExtensionWebStore: () => openBrowserExtensionWebStore(),
    extensionArchivePath: () => extensionArchive,
    extensionIconPath: () => join(developmentExtensionPath, "icons", "128.png"),
    configureExtensionRelay: (baseUrl) => {
      relayBaseUrl = baseUrl
      prepareBrowserExtension(dataDir, baseUrl)
    },
    subscribePreview: previews.subscribe,
    invoke: async (context, toolName, args) => {
      contexts.set(context.sessionId, context)
      if (toolName === "reset") {
        await repls.reset(context.sessionId)
        return jsonResult({ reset: true })
      }
      if (toolName === "js")
        return repls.execute(
          context.sessionId,
          typeof args.code === "string" ? args.code : "",
          async (name, nested) => {
            if (context.invokeBrowser) return context.invokeBrowser(name, nested)
            return browserResultValue(await provider.invoke(context, name, nested))
          }
        )
      if (toolName === "status") return jsonResult(await browserStatus(context))
      if (toolName === "request_extension_install")
        return textToolResult("The install prompt is shown through the Codevisor gateway", true)
      if (toolName === "use_backend") {
        const backend = args.backend
        if (backend !== "managed" && backend !== "extension" && backend !== "builtin") {
          return textToolResult("backend must be managed, extension, or builtin", true)
        }
        if (
          backend === "extension" &&
          !existsSync(join(developmentExtensionPath, "manifest.json"))
        ) {
          return textToolResult("The Codevisor Chrome extension resources are missing", true)
        }
        sessionBackends.set(context.sessionId, backend)
        return jsonResult(await browserStatus(context))
      }
      if (!browserUseTools.some((candidate) => candidate.name === toolName)) {
        return textToolResult(`Unknown Browser Use tool: ${toolName}`, true)
      }
      const backend = sessionBackends.get(context.sessionId)
      if (
        toolName === "finalizeTabs" &&
        args.native === true &&
        (backend === undefined ||
          !sessionTargets.has(`${runtimeKey(context, backend)}:${context.sessionId}`))
      )
        return jsonResult({ finalized: true, kept: [], closed: [], released: [] })
      if (backend === undefined) return noBrowserSelectedResult(await browserStatus(context))
      let effectiveTool = toolName
      let effectiveArgs = args
      if (toolName === "openTabs") {
        effectiveTool = "tabs"
        effectiveArgs = { action: "list" }
      } else if (toolName === "claimTab") {
        effectiveTool = "tabs"
        effectiveArgs = {
          action: "select",
          ...(typeof args.id === "string" ? { id: args.id } : { index: args.index }),
          title: args.title,
          url: args.url
        }
      }
      if (backend === "extension" && !extensionConnected())
        return chromeNotConnectedResult(await browserStatus(context))
      if (backend === "builtin") {
        const previous = await runtimes.get(runtimeKey(context, backend))?.catch(() => undefined)
        if (previous?.native === true && previous.connection.closed)
          return dropNativeRuntime(context, previous)
      }
      let active: BrowserRuntime | undefined
      try {
        active = await runtime(context, backend)
        if (active.native && active.connection.closed)
          throw new Error("Native browser disconnected")
        const ready = active
        if (effectiveTool === "playwright.waitForEvent") {
          return await invokeTool(context, ready, effectiveTool, effectiveArgs)
        }
        const result = await serializedBrowserOperation(ready, async () => {
          await ready.synchronizeCookies?.().catch(() => undefined)
          const invoked = await invokeTool(context, ready, effectiveTool, effectiveArgs)
          await ready.synchronizeCookies?.().catch(() => undefined)
          return invoked
        })
        const key = `${runtimeKey(context, backend)}:${context.sessionId}`
        const named = effectiveArgs.tabId
        const shown = typeof named === "string" ? named : selectedTargets.get(key)
        if (shown !== undefined) void previews.activity(context.sessionId, ready, shown)
        return result
      } catch (cause) {
        if (
          active?.native &&
          (active.connection.closed || /timed out|disconnected/i.test(String(cause)))
        )
          return dropNativeRuntime(context, active)
        return textToolResult(cause instanceof Error ? cause.message : String(cause), true)
      }
    },
    finishTurn: async (sessionId) => {
      const context = contexts.get(sessionId)
      await previews.finish(sessionId)
      if (context === undefined) return
      await finishSessionTabs(context, sessionTargets, runtimes, invokeTool)
    },
    closeSession: async (sessionId) => {
      const nativeKey = contexts.has(sessionId)
        ? runtimeKey(contexts.get(sessionId)!, "builtin")
        : undefined
      await provider.finishTurn?.(sessionId).catch(() => undefined)
      await previews.close(sessionId)
      contexts.delete(sessionId)
      await repls.reset(sessionId)
      sessionBackends.delete(sessionId)
      clientPlatforms.delete(sessionId)
      fallbackReasons.delete(sessionId)
      hosts.forgetSession(sessionId)
      const suffix = `:${sessionId}`
      const keys = new Set(
        [...selectedTargets.keys(), ...sessionTargets.keys(), ...sessionDispositions.keys()].filter(
          (key) => key.endsWith(suffix)
        )
      )
      for (const key of keys) {
        const targets = new Set(sessionTargets.get(key)?.keys() ?? [])
        const selected = selectedTargets.get(key)
        if (selected !== undefined) targets.add(selected)
        selectedTargets.delete(key)
        sessionTargets.delete(key)
        sessionDispositions.delete(key)
        const active = runtimes.get(key.slice(0, -(sessionId.length + 1)))
        const resolved = await active?.catch(() => undefined)
        if (resolved === undefined) continue
        for (const targetId of targets) {
          const tabSessionId = resolved.sessions.get(targetId)
          if (tabSessionId !== undefined) {
            await resolved.connection
              .send("Target.detachFromTarget", { sessionId: tabSessionId })
              .catch(() => undefined)
          }
          discardTargetState(resolved, targetId)
        }
      }
      if (nativeKey) {
        const active = await runtimes.get(nativeKey)?.catch(() => undefined)
        if (active?.native) {
          runtimes.delete(nativeKey)
          await closeBrowserRuntime(active)
        }
      }
    },
    close: async () => {
      await repls.close()
      contexts.clear()
      const active = [
        ...runtimes.values(),
        ...[...retiredRuntimes].map((retired) => Promise.resolve(retired))
      ]
      retiredRuntimes.clear()
      runtimes.clear()
      stopRelayLifecycle()
      hosts.close()
      await extensionRelay.close()
      await Promise.all(
        active.map(async (pending) => {
          const resolved = await pending.catch(() => undefined)
          if (resolved !== undefined) await closeBrowserRuntime(resolved)
        })
      )
    }
  }
  return provider
}

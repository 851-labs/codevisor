import { makeBrowserRuntimeFactory } from "./browser-runtime-factory.js"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { serializedBrowserOperation, closeBrowserRuntime } from "./browser-runtime-lifecycle.js"
import { makeBrowserRepls, browserResultValue } from "./browser-repl.js"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { existsSync, mkdirSync } from "node:fs"
import { join } from "node:path"
import type { AutomationProviderContext } from "./automation-provider.js"
import { textToolResult } from "./automation-provider.js"
import { CdpConnection } from "./browser-cdp.js"
import { discardTargetState, jsonResult, type BrowserRuntime } from "./browser-cdp-engine.js"
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
  CODEVISOR_BROWSER_EXTENSION_ID,
  makeBrowserExtensionRelay,
  openBrowserExtensionDevelopmentFolder,
  openBrowserExtensionDevelopmentInstaller,
  openBrowserExtensionDevelopmentPage,
  openBrowserExtensionWebStore,
  prepareBrowserExtension
} from "./browser-extension-relay.js"
import {
  makeBrowserToolInvoker,
  runtimeKey,
  type BrowserAssetInventory
} from "./browser-use-invoke.js"
import { browserUseTools } from "./browser-use-tools.js"

export { managedBrowserSandboxArguments } from "./browser-chromium.js"
export type { ManagedBrowserLaunchEnvironment } from "./browser-chromium.js"
export { browserKeyDescription } from "./browser-input.js"
export { browserUseTools } from "./browser-use-tools.js"

export type {
  BrowserBackend,
  BrowserExtensionSetupMode,
  BrowserUseProviderStatus,
  BrowserUseProvider
} from "./browser-use-provider-types.js"
import type {
  BrowserBackend,
  BrowserExtensionSetupMode,
  BrowserUseProvider
} from "./browser-use-provider-types.js"

export const makeBrowserUseProvider = (
  dataDir: string,
  db?: CodevisorDatabaseService
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
  const selectedTargets = new Map<string, string>()
  const sessionTargets = new Map<string, Map<string, "created" | "claimed">>()
  const sessionDispositions = new Map<string, Map<string, "deliverable" | "handoff">>()
  const assetInventories = new Map<string, BrowserAssetInventory>()
  const extensionRelay = makeBrowserExtensionRelay()
  const developmentExtensionPath = prepareBrowserExtension(dataDir, "http://127.0.0.1:49361")
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

  const extensionEndpoint = (): string | undefined => process.env.CODEVISOR_BROWSER_CDP_URL
  const status = () => {
    const extension = browserExtensionInstallation()
    return {
      engine: "codevisor-cdp",
      backend:
        systemChromePath() !== undefined
          ? "systemChrome"
          : downloadedChromiumPath(browsersDir) !== undefined
            ? "downloadedChromium"
            : "missing",
      extensionAvailable: extension.bundled,
      extensionInstalled: extension.installed,
      extensionInstallationState: extension.installationState,
      extensionConnected: extensionEndpoint() !== undefined || extensionRelay.connected(),
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
    dataDir,
    db,
    profilesDir,
    browsersDir,
    downloadsDir,
    fallbackReasons,
    ensureSetup,
    connectExtension: () => {
      const endpoint = extensionEndpoint()
      return endpoint === undefined ? extensionRelay.connect() : CdpConnection.connect(endpoint)
    }
  })

  const runtime = (
    context: AutomationProviderContext,
    backend: BrowserBackend
  ): Promise<BrowserRuntime> => {
    const key = runtimeKey(context, backend)
    const existing = runtimes.get(key)
    if (existing !== undefined) return existing
    const created = createRuntime(context, backend)
      .then((active) => {
        if (!active) throw new Error("Browser initialization did not produce a connection")
        return active
      })
      .catch((cause) => {
        runtimes.delete(key)
        throw cause
      })
    runtimes.set(key, created)
    return created
  }

  const extensionConnectionResult = (): CallToolResult =>
    jsonResult({
      backend: "extension",
      connectionState:
        extensionEndpoint() !== undefined || extensionRelay.connected()
          ? "connected"
          : "needs_setup",
      connected: extensionEndpoint() !== undefined || extensionRelay.connected(),
      next:
        extensionEndpoint() !== undefined || extensionRelay.connected()
          ? "Call openTabs, then claimTab before inspecting or changing a page."
          : "Chrome is not connected. Codevisor handles browser selection and extension setup in the composer."
    })

  const connectionStatus = async (context: AutomationProviderContext) => {
    const requestedBackend = sessionBackends.get(context.sessionId)
    const active =
      requestedBackend &&
      (await runtimes.get(runtimeKey(context, requestedBackend))?.catch(() => undefined))
    const connected =
      requestedBackend === "extension"
        ? extensionEndpoint() !== undefined || extensionRelay.connected()
        : active !== undefined && !active.connection.closed
    return {
      requestedBackend: requestedBackend ?? "unconfigured",
      backend:
        requestedBackend === "extension"
          ? "extension"
          : active
            ? active.native
              ? "builtin"
              : requestedBackend === "builtin"
                ? "managed"
                : requestedBackend
            : "unconnected",
      connected,
      connectionState: connected ? "connected" : "disconnected",
      localOnly: true,
      ...(requestedBackend === "builtin" && fallbackReasons.has(context.sessionId)
        ? {
            fallbackReason: fallbackReasons.get(context.sessionId),
            retry: "The local built-in browser is checked again at the next response."
          }
        : {})
    }
  }

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
    beginTurn: async (sessionId, backend) => {
      const previous = sessionBackends.get(sessionId)
      sessionBackends.set(sessionId, backend)
      const context = contexts.get(sessionId)
      let changed = previous !== backend
      if (context && backend === "builtin") {
        const key = runtimeKey(context, backend)
        const current = await runtimes.get(key)?.catch(() => undefined)
        if (!current && fallbackReasons.has(sessionId)) changed = true
        fallbackReasons.delete(sessionId)
        if (current && (!current.native || current.connection.closed)) {
          const native = await createRuntime(context, "builtin", true)
          if (native || current.connection.closed) {
            runtimes.delete(key)
            // Retain managed processes and handoff tabs until provider shutdown.
            // Another session may be using the same fallback profile.
            retiredRuntimes.add(current)
            if (native) runtimes.set(key, Promise.resolve(native))
            changed = true
          }
        }
      }
      if (changed) await discardSessionHandles(sessionId)
    },
    acceptExtensionConnection: (socket) => {
      runtimes.delete("extension")
      extensionRelay.accept(socket)
    },
    waitForExtensionConnection: async () => {
      if (extensionEndpoint() !== undefined || extensionRelay.connected()) return
      await extensionRelay.connect()
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
    configureExtensionRelay: (serverBaseUrl) => {
      prepareBrowserExtension(dataDir, serverBaseUrl)
    },
    invoke: async (context, toolName, args) => {
      contexts.set(context.sessionId, context)
      if (toolName === "reset") {
        await repls.reset(context.sessionId)
        return jsonResult({ reset: true })
      }
      if (toolName === "js")
        return repls.execute(context.sessionId, String(args.code ?? ""), async (name, nested) => {
          if (context.invokeBrowser) return context.invokeBrowser(name, nested)
          return browserResultValue(await provider.invoke(context, name, nested))
        })
      if (toolName === "backends") {
        const extension = browserExtensionInstallation()
        const current = await connectionStatus(context)
        return jsonResult({
          preferred: sessionBackends.get(context.sessionId),
          current,
          builtin: {
            available:
              current.backend === "builtin"
                ? current.connected
                : fallbackReasons.has(context.sessionId)
                  ? false
                  : null,
            fallback: "managed",
            localOnly: true
          },
          managed: { available: status().backend !== "missing", engine: "codevisor-cdp" },
          extension: {
            available: extension.bundled,
            bundled: extension.bundled,
            installed: extension.installed,
            installationState: extension.installationState,
            browserOpen: userChromiumIsRunning(),
            connectionState:
              extensionEndpoint() !== undefined || extensionRelay.connected()
                ? "connected"
                : "needs_setup",
            connected: extensionEndpoint() !== undefined || extensionRelay.connected(),
            engine: "codevisor-cdp-relay",
            extensionId: CODEVISOR_BROWSER_EXTENSION_ID,
            installPath: developmentExtensionPath,
            detail:
              "Codevisor's composer handles extension setup. A connected relay is the authoritative readiness signal."
          }
        })
      }
      if (toolName === "connection_status") {
        const backend = sessionBackends.get(context.sessionId)
        if (backend === undefined)
          return jsonResult({
            backend: "unconfigured",
            connectionState: "needs_selection",
            connected: false
          })
        if (backend === "extension") return extensionConnectionResult()
        return jsonResult(await connectionStatus(context))
      }
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
        if (backend === "extension") return extensionConnectionResult()
        return jsonResult(await connectionStatus(context))
      }
      if (!browserUseTools.some((candidate) => candidate.name === toolName)) {
        return textToolResult(`Unknown Browser Use tool: ${toolName}`, true)
      }
      const backend = sessionBackends.get(context.sessionId) ?? "builtin"
      sessionBackends.set(context.sessionId, backend)
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
      if (
        backend === "extension" &&
        extensionEndpoint() === undefined &&
        !extensionRelay.connected()
      )
        return textToolResult("Chrome is not connected to Codevisor", true)
      let active: BrowserRuntime | undefined
      try {
        active = await runtime(context, backend)
        if (active.native && active.connection.closed)
          throw new Error("Native browser disconnected")
        const ready = active
        if (effectiveTool === "playwright.waitForEvent") {
          return await invokeTool(context, ready, effectiveTool, effectiveArgs)
        }
        return await serializedBrowserOperation(ready, async () => {
          await ready.synchronizeCookies?.().catch(() => undefined)
          const result = await invokeTool(context, ready, effectiveTool, effectiveArgs)
          await ready.synchronizeCookies?.().catch(() => undefined)
          return result
        })
      } catch (cause) {
        if (
          active?.native &&
          (active.connection.closed || /timed out|disconnected/i.test(String(cause)))
        ) {
          fallbackReasons.set(
            context.sessionId,
            "The local built-in browser disconnected during an action."
          )
          runtimes.delete(runtimeKey(context, backend))
          for (const dispose of active.eventDisposers) dispose()
          await active.connection.close()
          const key = `${runtimeKey(context, backend)}:${context.sessionId}`
          selectedTargets.delete(key)
          sessionTargets.delete(key)
          sessionDispositions.delete(key)
          return textToolResult(
            "The built-in browser disconnected. The next browser call will use independent Chromium on this server. The interrupted action was NOT retried; its outcome may be unknown. Discard old tab IDs, locators and snapshots, then open or observe a new tab before continuing.",
            true
          )
        }
        return textToolResult(cause instanceof Error ? cause.message : String(cause), true)
      }
    },
    finishTurn: async (sessionId) => {
      const context = contexts.get(sessionId)
      const backend = sessionBackends.get(sessionId)
      if (!context || !backend) return
      const key = runtimeKey(context, backend)
      if (!sessionTargets.has(`${key}:${sessionId}`)) return
      const active = await runtimes.get(key)
      if (active)
        await serializedBrowserOperation(active, () =>
          invokeTool(context, active, "finalizeTabs", { native: true })
        )
    },
    closeSession: async (sessionId) => {
      const nativeKey = contexts.has(sessionId)
        ? runtimeKey(contexts.get(sessionId)!, "builtin")
        : undefined
      await provider.finishTurn?.(sessionId)
      contexts.delete(sessionId)
      await repls.reset(sessionId)
      sessionBackends.delete(sessionId)
      fallbackReasons.delete(sessionId)
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
        // Native connections belong to the agent session. Closing them detaches
        // automation while leaving the user's panes and the app running.
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
        ...[...retiredRuntimes].map((active) => Promise.resolve(active))
      ]
      retiredRuntimes.clear()
      runtimes.clear()
      stopRelayLifecycle()
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

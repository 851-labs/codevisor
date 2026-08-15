import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { createHash, randomUUID } from "node:crypto"
import { existsSync, mkdirSync } from "node:fs"
import { join } from "node:path"
import type { ChildProcess } from "node:child_process"
import type { AutomationProviderContext, AutomationToolProvider } from "./automation-provider.js"
import { textToolResult } from "./automation-provider.js"
import { CdpConnection, delay } from "./browser-cdp.js"
import { jsonResult, type BrowserRuntime } from "./browser-cdp-engine.js"
import {
  downloadedChromiumPath,
  launchManagedBrowser,
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
import type WebSocket from "ws"

export { managedBrowserSandboxArguments } from "./browser-chromium.js"
export type { ManagedBrowserLaunchEnvironment } from "./browser-chromium.js"
export { browserKeyDescription } from "./browser-input.js"
export { browserUseTools } from "./browser-use-tools.js"

export type BrowserBackend = "managed" | "extension"
export type BrowserExtensionSetupMode = "development" | "webStore"

export interface BrowserUseProviderStatus extends Readonly<Record<string, unknown>> {
  readonly extensionConnected: boolean
  readonly chromeAvailable: boolean
  readonly extensionSetupMode: BrowserExtensionSetupMode
  readonly developmentExtensionPath?: string
  readonly extensionArchivePath?: string
}

export interface BrowserUseProvider extends AutomationToolProvider {
  readonly ensureSetup: () => Promise<void>
  readonly status: () => BrowserUseProviderStatus
  readonly sessionBackend: (sessionId: string) => BrowserBackend | undefined
  readonly setSessionBackend: (sessionId: string, backend: BrowserBackend) => void
  readonly acceptExtensionConnection: (socket: WebSocket) => void
  readonly waitForExtensionConnection: () => Promise<void>
  readonly onExtensionConnectionChange: (listener: (connected: boolean) => void) => () => void
  readonly openDevelopmentExtensionFolder: () => void
  readonly openDevelopmentExtensionPage: () => void
  readonly openDevelopmentExtensionInstaller: () => void
  readonly openExtensionWebStore: () => void
  readonly extensionArchivePath: () => string
  readonly extensionIconPath: () => string
  readonly configureExtensionRelay: (serverBaseUrl: string) => void
}

export const makeBrowserUseProvider = (dataDir: string): BrowserUseProvider => {
  const browsersDir = join(dataDir, "browser", "browsers")
  const profilesDir = join(dataDir, "browser", "profiles")
  const downloadsDir = join(dataDir, "browser", "downloads")
  const assetsDir = join(dataDir, "browser", "assets")
  mkdirSync(browsersDir, { recursive: true, mode: 0o700 })
  mkdirSync(profilesDir, { recursive: true, mode: 0o700 })
  mkdirSync(downloadsDir, { recursive: true, mode: 0o700 })
  mkdirSync(assetsDir, { recursive: true, mode: 0o700 })
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

  const profileKey = (context: AutomationProviderContext): string =>
    createHash("sha256")
      .update(context.projectId ?? "global")
      .digest("hex")
      .slice(0, 24)

  const createRuntime = async (
    context: AutomationProviderContext,
    backend: BrowserBackend
  ): Promise<BrowserRuntime> => {
    let connection: CdpConnection
    let processHandle: ChildProcess | undefined
    let owned = false
    if (backend === "extension") {
      const endpoint = extensionEndpoint()
      connection =
        endpoint === undefined
          ? await extensionRelay.connect()
          : await CdpConnection.connect(endpoint)
    } else {
      await ensureSetup()
      const executablePath = systemChromePath() ?? downloadedChromiumPath(browsersDir)
      if (executablePath === undefined) throw new Error("No managed Chromium is installed")
      const profileDir = join(profilesDir, profileKey(context))
      mkdirSync(profileDir, { recursive: true, mode: 0o700 })
      const launched = await launchManagedBrowser(executablePath, profileDir)
      connection = launched.connection
      processHandle = launched.processHandle
      owned = launched.processHandle !== undefined
    }
    await connection.send("Target.setDiscoverTargets", { discover: true })
    const active: BrowserRuntime = {
      connection,
      processHandle,
      owned,
      sessions: new Map(),
      snapshots: new Map(),
      eventLog: [],
      logs: new Map(),
      dialogs: new Map(),
      fileChoosers: new Map(),
      downloads: new Map(),
      eventDisposers: [],
      eventSequence: 0,
      tabOrder: [],
      queue: Promise.resolve()
    }
    active.eventDisposers.push(
      connection.on("*", (params, event) => {
        const sequence = ++active.eventSequence
        active.eventLog.push({
          method: event.method,
          params,
          sequence,
          ...(event.sessionId === undefined ? {} : { sessionId: event.sessionId })
        })
        if (active.eventLog.length > 5_000)
          active.eventLog.splice(0, active.eventLog.length - 5_000)
        if (event.sessionId !== undefined) {
          if (
            event.method === "Runtime.consoleAPICalled" ||
            event.method === "Runtime.exceptionThrown" ||
            event.method === "Log.entryAdded"
          ) {
            const entries = active.logs.get(event.sessionId) ?? []
            entries.push({ method: event.method, ...params, sequence })
            if (entries.length > 1_000) entries.splice(0, entries.length - 1_000)
            active.logs.set(event.sessionId, entries)
          } else if (event.method === "Page.javascriptDialogOpening") {
            active.dialogs.set(event.sessionId, { ...params })
          } else if (event.method === "Page.javascriptDialogClosed") {
            active.dialogs.delete(event.sessionId)
          }
        }
        if (
          event.method === "Browser.downloadWillBegin" ||
          event.method === "Page.downloadWillBegin"
        ) {
          const guid = typeof params.guid === "string" ? params.guid : randomUUID()
          active.downloads.set(guid, {
            guid,
            url: String(params.url ?? ""),
            suggestedFilename: String(params.suggestedFilename ?? "download"),
            ...(typeof params.filePath === "string" ? { path: params.filePath } : {})
          })
        } else if (
          (event.method === "Browser.downloadProgress" ||
            event.method === "Page.downloadProgress") &&
          typeof params.guid === "string"
        ) {
          const existing = active.downloads.get(params.guid)
          if (existing !== undefined) {
            active.downloads.set(params.guid, {
              ...existing,
              ...(typeof params.state === "string"
                ? { state: params.state }
                : existing.state === undefined
                  ? {}
                  : { state: existing.state }),
              ...(typeof params.filePath === "string"
                ? { path: params.filePath }
                : params.state === "completed" && existing.path === undefined
                  ? { path: join(downloadsDir, params.guid) }
                  : {})
            })
          }
        }
      })
    )
    return active
  }

  const runtime = (
    context: AutomationProviderContext,
    backend: BrowserBackend
  ): Promise<BrowserRuntime> => {
    const key = runtimeKey(context, backend)
    const existing = runtimes.get(key)
    if (existing !== undefined) return existing
    const created = createRuntime(context, backend).catch((cause) => {
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

  const serialized = async <T>(active: BrowserRuntime, operation: () => Promise<T>): Promise<T> => {
    let release = (): void => undefined
    const previous = active.queue
    active.queue = new Promise<void>((resolve) => {
      release = resolve
    })
    await previous
    try {
      return await operation()
    } finally {
      release()
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

  const closeRuntime = async (active: BrowserRuntime): Promise<void> => {
    await active.queue.catch(() => undefined)
    for (const dispose of active.eventDisposers.splice(0)) dispose()
    if (active.owned) {
      await active.connection.send("Browser.close").catch(() => undefined)
      if (active.processHandle !== undefined && active.processHandle.exitCode === null) {
        await Promise.race([
          new Promise<void>((resolve) => active.processHandle!.once("exit", () => resolve())),
          delay(500)
        ])
      }
      if (active.processHandle !== undefined && active.processHandle.exitCode === null) {
        active.processHandle.kill("SIGTERM")
        await Promise.race([
          new Promise<void>((resolve) => active.processHandle!.once("exit", () => resolve())),
          delay(1_500)
        ])
      }
    }
    await active.connection.close().catch(() => undefined)
  }

  return {
    id: "browser",
    tools: browserUseTools,
    ensureSetup,
    status,
    sessionBackend: (sessionId) => sessionBackends.get(sessionId),
    setSessionBackend: (sessionId, backend) => sessionBackends.set(sessionId, backend),
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
      if (toolName === "backends") {
        const extension = browserExtensionInstallation()
        return jsonResult({
          preferred: sessionBackends.get(context.sessionId),
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
        return jsonResult({ backend, connectionState: "connected", connected: true })
      }
      if (toolName === "use_backend") {
        const backend = args.backend
        if (backend !== "managed" && backend !== "extension") {
          return textToolResult("backend must be managed or extension", true)
        }
        if (
          backend === "extension" &&
          !existsSync(join(developmentExtensionPath, "manifest.json"))
        ) {
          return textToolResult("The Codevisor Chrome extension resources are missing", true)
        }
        sessionBackends.set(context.sessionId, backend)
        if (backend === "extension") return extensionConnectionResult()
        return jsonResult({ backend, engine: "codevisor-cdp", connectionState: "connected" })
      }
      if (!browserUseTools.some((candidate) => candidate.name === toolName)) {
        return textToolResult(`Unknown Browser Use tool: ${toolName}`, true)
      }
      const backend = sessionBackends.get(context.sessionId) ?? "managed"
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
          ...(typeof args.id === "string" ? { id: args.id } : { index: args.index })
        }
      }
      if (
        backend === "extension" &&
        extensionEndpoint() === undefined &&
        !extensionRelay.connected()
      )
        return textToolResult("Chrome is not connected to Codevisor", true)
      try {
        const active = await runtime(context, backend)
        if (effectiveTool === "playwright.waitForEvent") {
          return await invokeTool(context, active, effectiveTool, effectiveArgs)
        }
        return await serialized(active, () =>
          invokeTool(context, active, effectiveTool, effectiveArgs)
        )
      } catch (cause) {
        return textToolResult(cause instanceof Error ? cause.message : String(cause), true)
      }
    },
    closeSession: async (sessionId) => {
      sessionBackends.delete(sessionId)
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
          resolved.sessions.delete(targetId)
          resolved.snapshots.delete(targetId)
        }
      }
    },
    close: async () => {
      const active = [...runtimes.values()]
      runtimes.clear()
      stopRelayLifecycle()
      await extensionRelay.close()
      await Promise.all(
        active.map(async (pending) => {
          const resolved = await pending.catch(() => undefined)
          if (resolved !== undefined) await closeRuntime(resolved)
        })
      )
    }
  }
}

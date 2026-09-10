import { createHash } from "node:crypto"
import { mkdirSync } from "node:fs"
import { join } from "node:path"
import type { ChildProcess } from "node:child_process"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { AutomationProviderContext } from "./automation-provider.js"
import { CdpConnection } from "./browser-cdp.js"
import type { BrowserRuntime } from "./browser-cdp-engine.js"
import type { BrowserBackend } from "./browser-use-provider-types.js"
import { connectNativeBrowser } from "./browser-native-connection.js"
import { synchronizeManagedCookies } from "./browser-cookie-sync.js"
import { closeBrowserRuntime } from "./browser-runtime-lifecycle.js"
import { observeBrowserRuntime } from "./browser-runtime-events.js"
import {
  downloadedChromiumPath,
  launchManagedBrowser,
  systemChromePath
} from "./browser-chromium.js"

export const makeBrowserRuntimeFactory = (options: {
  dataDir: string
  db: CodevisorDatabaseService | undefined
  profilesDir: string
  browsersDir: string
  downloadsDir: string
  fallbackReasons: Map<string, string>
  ensureSetup: () => Promise<void>
  connectExtension: () => Promise<CdpConnection>
}) => {
  const { dataDir, db, profilesDir, browsersDir, downloadsDir, fallbackReasons, ensureSetup } =
    options
  const profileKey = (context: AutomationProviderContext): string =>
    createHash("sha256")
      .update(context.projectId ?? "global")
      .digest("hex")
      .slice(0, 24)

  let fallbackLaunch: Promise<unknown> = Promise.resolve()

  const createRuntime = async (
    context: AutomationProviderContext,
    backend: BrowserBackend,
    nativeOnly = false
  ): Promise<BrowserRuntime | undefined> => {
    let connection: CdpConnection
    let processHandle: ChildProcess | undefined
    let owned = false
    let native = false
    if (backend === "extension") {
      connection = await options.connectExtension()
    } else {
      const local =
        backend === "builtin" && !fallbackReasons.has(context.sessionId)
          ? await connectNativeBrowser(dataDir, context.sessionId)
          : undefined
      if (local?.connection) {
        connection = local.connection
        native = true
      } else {
        if (backend === "builtin" && local?.reason)
          fallbackReasons.set(context.sessionId, local.reason)
        if (nativeOnly) return undefined
        await ensureSetup()
        const executablePath = systemChromePath() ?? downloadedChromiumPath(browsersDir)
        if (executablePath === undefined) throw new Error("No managed Chromium is installed")
        const profileDir = join(
          profilesDir,
          backend === "builtin" ? "builtin" : profileKey(context)
        )
        mkdirSync(profileDir, { recursive: true, mode: 0o700 })
        // Serialize access to the shared fallback profile so concurrent sessions
        // connect to one process instead of racing Chromium's profile lock.
        const launch = () => launchManagedBrowser(executablePath, profileDir)
        const pendingLaunch = backend === "builtin" ? fallbackLaunch.then(launch, launch) : launch()
        if (backend === "builtin") fallbackLaunch = pendingLaunch.catch(() => undefined)
        const launched = await pendingLaunch
        connection = launched.connection
        processHandle = launched.processHandle
        owned = launched.processHandle !== undefined
      }
    }
    try {
      await connection.send(
        "Target.setDiscoverTargets",
        { discover: true },
        undefined,
        native ? 5000 : undefined
      )
    } catch (cause) {
      await connection.close().catch(() => undefined)
      if (native) {
        // Initialization has not executed a browser action, so fallback here
        // cannot repeat a click or submit a form twice.
        fallbackReasons.set(
          context.sessionId,
          "The local built-in browser is not ready. Check the Codevisor app on this machine for a blocking dialog or browser error."
        )
        if (nativeOnly) return undefined
        return createRuntime(context, backend)
      }
      processHandle?.kill("SIGTERM")
      throw cause
    }
    const active: BrowserRuntime = {
      connection,
      native,
      processHandle,
      owned,
      sessions: new Map(),
      staleSessions: new Map(),
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
    if (native)
      active.synchronizeCookies = async () => {
        await connection.send("Codevisor.synchronizeCookies")
      }
    if (db && backend === "builtin" && !native) {
      try {
        const sync = await synchronizeManagedCookies(connection, db)
        active.synchronizeCookies = sync.synchronize
        active.eventDisposers.push(sync.stop)
      } catch (cause) {
        await closeBrowserRuntime(active)
        throw cause
      }
    }
    observeBrowserRuntime(active, downloadsDir, backend === "extension")
    return active
  }

  return createRuntime
}

import type { ChildProcess } from "node:child_process"
import { createHash } from "node:crypto"
import { mkdirSync } from "node:fs"
import { join } from "node:path"

import type { AutomationProviderContext } from "./automation-provider.js"
import type { BrowserRuntime, NativeBrowserHost } from "./browser-cdp-engine.js"
import type { CdpConnection } from "./browser-cdp.js"
import {
  downloadedChromiumPath,
  launchManagedBrowser,
  systemChromePath
} from "./browser-chromium.js"
import { synchronizeManagedCookies, type ExchangeBrowserCookies } from "./browser-cookie-sync.js"
import type { BrowserHostConnection } from "./browser-host-registry.js"
import { observeBrowserRuntime } from "./browser-runtime-events.js"
import { closeBrowserRuntime } from "./browser-runtime-lifecycle.js"
import type { BrowserBackend } from "./browser-use-provider-types.js"
import { builtinUnreachableMessage } from "./browser-use-status.js"

class BuiltinBrowserUnreachable extends Error {
  constructor(reason: string) {
    super(builtinUnreachableMessage(reason))
    this.name = "BuiltinBrowserUnreachable"
  }
}

const nativeSetupTimeoutMs = 5000

const profileKey = (context: AutomationProviderContext): string =>
  createHash("sha256")
    .update(context.projectId ?? "global")
    .digest("hex")
    .slice(0, 24)

interface OpenedBrowser {
  readonly connection: CdpConnection
  readonly processHandle?: ChildProcess | undefined
  readonly nativeHost?: NativeBrowserHost
}

export const makeBrowserRuntimeFactory = (options: {
  profilesDir: string
  browsersDir: string
  downloadsDir: string
  ensureSetup: () => Promise<void>
  connectNative: (sessionId: string) => Promise<BrowserHostConnection>
  connectExtension: () => Promise<CdpConnection>
  exchangeCookies?: ExchangeBrowserCookies | undefined
}) => {
  const { profilesDir, browsersDir, downloadsDir, ensureSetup } = options

  const openNative = async (context: AutomationProviderContext): Promise<OpenedBrowser> => {
    const local = await options.connectNative(context.sessionId)
    if (local.connection === undefined) throw new BuiltinBrowserUnreachable(local.reason)

    const { host, showing } = local
    return { connection: local.connection, nativeHost: { id: host.id, name: host.name, showing } }
  }

  const openManaged = async (context: AutomationProviderContext): Promise<OpenedBrowser> => {
    await ensureSetup()
    const executablePath = systemChromePath() ?? downloadedChromiumPath(browsersDir)
    if (executablePath === undefined) throw new Error("No managed Chromium is installed")

    const profileDir = join(profilesDir, profileKey(context))
    mkdirSync(profileDir, { recursive: true, mode: 0o700 })
    return launchManagedBrowser(executablePath, profileDir)
  }

  const open = (context: AutomationProviderContext, backend: BrowserBackend) => {
    if (backend === "extension")
      return options.connectExtension().then((connection) => ({ connection }))
    if (backend === "builtin") return openNative(context)
    return openManaged(context)
  }

  return async (
    context: AutomationProviderContext,
    backend: BrowserBackend
  ): Promise<BrowserRuntime> => {
    const opened = await open(context, backend)
    await discoverTargets(opened)
    const active = runtimeFor(opened)
    if (backend === "managed") await shareCookies(active, options.exchangeCookies)
    observeBrowserRuntime(active, downloadsDir, backend === "extension")
    return active
  }
}

const discoverTargets = async (opened: OpenedBrowser): Promise<void> => {
  try {
    await opened.connection.send(
      "Target.setDiscoverTargets",
      { discover: true },
      undefined,
      opened.nativeHost === undefined ? undefined : nativeSetupTimeoutMs
    )
  } catch (cause) {
    await opened.connection.close().catch(() => undefined)
    opened.processHandle?.kill("SIGTERM")
    if (opened.nativeHost === undefined) throw cause
    throw new BuiltinBrowserUnreachable(
      `The Codevisor app on ${opened.nativeHost.name} didn't start its built-in browser. Check that Mac for a blocking dialog or browser error.`
    )
  }
}

const shareCookies = async (
  active: BrowserRuntime,
  exchange: ExchangeBrowserCookies | undefined
): Promise<void> => {
  if (exchange === undefined) return
  try {
    const sync = await synchronizeManagedCookies(active.connection, exchange)
    active.synchronizeCookies = sync.synchronize
    active.eventDisposers.push(sync.stop)
  } catch (cause) {
    await closeBrowserRuntime(active)
    throw cause
  }
}

const runtimeFor = ({ connection, processHandle, nativeHost }: OpenedBrowser): BrowserRuntime => ({
  connection,
  native: nativeHost !== undefined,
  ...nativeFields(connection, nativeHost),
  processHandle,
  owned: processHandle !== undefined,
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
})

const nativeFields = (connection: CdpConnection, nativeHost: NativeBrowserHost | undefined) => {
  if (nativeHost === undefined) return {}
  return {
    nativeHost,
    synchronizeCookies: async () => {
      await connection.send("Codevisor.synchronizeCookies")
    }
  }
}

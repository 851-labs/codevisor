import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

import type { BackgroundTerminalIntegration } from "@codevisor/agent-runtime"
import type { DataUpgradeProgress, ScreenSharingRequest } from "@codevisor/api"
import { requestMacScreenSharing } from "@codevisor/automation"
import type { TerminalManagerService } from "@codevisor/terminal"

import {
  backgroundTerminalSocketPath,
  startBackgroundTerminalHost,
  wrapBackgroundCommand
} from "./infra/background-terminal-host.js"
import type { ServerLease } from "./infra/server-lease.js"
import { makeTerminalPersistence } from "./infra/terminal-persistence.js"
import { xfceScaler } from "./routes/screen-sharing-vnc-scale.js"
import { readScreenSharingVNC, vncScreenSharing } from "./routes/screen-sharing-vnc.js"
import type { ScreenSharingVNCConfig } from "./server-context-types.js"
import type { StartupReporter } from "./startup-progress.js"

/// Boot-time helpers for the `serve` entry point: argument parsing, bundle
/// metadata, data-upgrade status, app-owner monitoring, optional feature
/// initialization, and the background terminal integration.

export const SERVER_PROCESS_TITLE = "codevisor-server"
export const nativeScreenSharing = (dataDir: string) =>
  process.platform === "darwin"
    ? (request: ScreenSharingRequest) => requestMacScreenSharing(dataDir, request)
    : undefined
/// The native helper where it exists (macOS), else the operator's VNC
/// desktop, else no screen sharing at all.
export const screenSharingProvider = (
  dataDir: string
): {
  readonly screenSharing: ((request: ScreenSharingRequest) => Promise<unknown>) | undefined
  readonly screenSharingVNC: ScreenSharingVNCConfig | undefined
} => {
  const native = nativeScreenSharing(dataDir)
  if (native !== undefined) return { screenSharing: native, screenSharingVNC: undefined }
  const vnc = readScreenSharingVNC(dataDir)
  if (vnc === undefined) return { screenSharing: undefined, screenSharingVNC: undefined }
  // An Xfce desktop's scale can be set (851-2339); display N listens on 5900 + N.
  const scaler = vnc.desktop === "xfce" ? xfceScaler(vnc.port - 5900) : undefined
  return { screenSharing: vncScreenSharing(vnc, scaler), screenSharingVNC: vnc }
}
/// Background cache only: clients checking on the user's behalf pass
/// `force` (GET /v1/update?refresh=1) and bypass this entirely. Six hours
/// here made remote machines deny fresh releases for most of a day.
export const SERVER_UPDATE_CHECK_TTL_MS = 15 * 60 * 1_000

export const resolveServeModes = (
  args: Readonly<Record<string, string>>,
  host: string
): {
  readonly authMode: "none" | "token"
  readonly directPathMode: "enabled" | "disabled"
  readonly resolvedKind: "local" | "remote"
} => {
  const authMode = args.auth ?? (host === "127.0.0.1" ? "none" : "token")
  if (authMode !== "none" && authMode !== "token") {
    throw new Error("--auth must be either none or token")
  }
  const directPathMode = args["direct-path"] ?? "enabled"
  if (directPathMode !== "enabled" && directPathMode !== "disabled") {
    throw new Error("--direct-path must be either enabled or disabled")
  }
  const kind = args.kind
  if (kind !== undefined && kind !== "local" && kind !== "remote") {
    throw new Error("--kind must be either local or remote")
  }
  return {
    authMode,
    directPathMode,
    resolvedKind: kind ?? (host === "127.0.0.1" ? "local" : "remote")
  }
}

interface ServerWorkingDirectoryOps {
  readonly mkdir: (path: string) => void
  readonly chdir: (path: string) => void
}

/// Detaches the daemon from whichever bundle, shell, or updater staging
/// directory launched it. Long-lived servers outlive app-bundle swaps, so no
/// subprocess may inherit a cwd that Sparkle can later remove.
export const stabilizeServerWorkingDirectory = (
  databasePath: string,
  ops: ServerWorkingDirectoryOps = {
    mkdir: (path) => mkdirSync(path, { recursive: true }),
    chdir: (path) => process.chdir(path)
  }
): string => {
  const dataDirectory = dirname(databasePath)
  ops.mkdir(dataDirectory)
  ops.chdir(dataDirectory)
  return dataDirectory
}

export const failureMessage = (cause: unknown): string => {
  if (!(cause instanceof Error)) return String(cause)
  // Effect wraps rejected promises in an UnknownError. Preserve the useful
  // domain error (lease owner, migration failure, missing resource, …) rather
  // than reducing every startup failure to "An error occurred".
  if (cause.message === "An error occurred in Effect.tryPromise" && cause.cause !== undefined) {
    return failureMessage(cause.cause)
  }
  return cause.message
}

export const initializeOptionalServerFeature = <A>(
  name: string,
  initialize: () => A,
  report: (message: string) => void = console.error
): A | undefined => {
  try {
    return initialize()
  } catch (cause) {
    report(`${name} unavailable: ${failureMessage(cause)}`)
    return undefined
  }
}

export const initializeOptionalServerFeatureAsync = async <A>(
  name: string,
  initialize: () => Promise<A>,
  report: (message: string) => void = console.error
): Promise<A | undefined> => {
  try {
    return await initialize()
  } catch (cause) {
    report(`${name} unavailable: ${failureMessage(cause)}`)
    return undefined
  }
}

export interface BootScopedDataUpgradeProgress extends DataUpgradeProgress {
  readonly bootId: string
  readonly pid: number
  readonly updatedAt: string
}

export const writeDataUpgradeStatus = (
  path: string,
  bootId: string,
  progress: DataUpgradeProgress
): void => {
  mkdirSync(dirname(path), { recursive: true })
  const temporary = `${path}.${process.pid}.tmp`
  const scoped: BootScopedDataUpgradeProgress = {
    ...progress,
    bootId,
    pid: process.pid,
    updatedAt: new Date().toISOString()
  }
  writeFileSync(temporary, `${JSON.stringify(scoped)}\n`, "utf8")
  renameSync(temporary, path)
}

export const parseProcessId = (value: string | undefined): number | undefined => {
  if (value === undefined || value.length === 0) return undefined
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : undefined
}

const processIsAlive = (pid: number): boolean => {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

export const monitorAppOwner = (options: {
  readonly ownerPid: number
  readonly lease: Pick<ServerLease, "release">
  readonly intervalMilliseconds?: number
  readonly isAlive?: (pid: number) => boolean
  readonly stopProcess?: () => void
}): (() => void) => {
  const isAlive = options.isAlive ?? processIsAlive
  const stopProcess = options.stopProcess ?? (() => process.exit(0))
  const timer = setInterval(() => {
    if (isAlive(options.ownerPid)) return
    console.log(`Codevisor host app ${options.ownerPid} exited; stopping its local server`)
    clearInterval(timer)
    void options.lease.release().finally(stopProcess)
  }, options.intervalMilliseconds ?? 500)
  timer.unref()
  return () => clearInterval(timer)
}

/// Exit status used to hand an update back to a host macOS app: a server that
/// lives inside the .app bundle can't replace that bundle, so instead of
/// swapping a standalone runtime (which the app's next launch would discard) it
/// exits with this status and the app performs the full app update + relaunch.
/// Must match `LocalCodevisorServer.updateHandoffExitStatus`.
export { parseServeArgs as parseArgs } from "./startup-progress.js"

export const bundledVersion = (): string | undefined => {
  const override = process.env.CODEVISOR_VERSION ?? process.env.HERDMAN_VERSION
  if (override !== undefined && override.length > 0) {
    return override
  }

  const versionPath = join(dirname(fileURLToPath(import.meta.url)), "VERSION")
  if (!existsSync(versionPath)) {
    return undefined
  }

  const version = readFileSync(versionPath, "utf8").trim()
  return version.length > 0 ? version : undefined
}

export const bundledBuildMetadata = (): {
  readonly buildNumber?: number
  readonly sourceRevision?: string
} => {
  const metadataPath = join(dirname(fileURLToPath(import.meta.url)), "BUILD.json")
  if (!existsSync(metadataPath)) return {}
  try {
    const value = JSON.parse(readFileSync(metadataPath, "utf8")) as {
      readonly buildNumber?: unknown
      readonly sourceRevision?: unknown
    }
    const buildNumber =
      typeof value.buildNumber === "number" && Number.isSafeInteger(value.buildNumber)
        ? value.buildNumber
        : undefined
    const sourceRevision =
      typeof value.sourceRevision === "string" && value.sourceRevision.length > 0
        ? value.sourceRevision
        : undefined
    return {
      ...(buildNumber === undefined ? {} : { buildNumber }),
      ...(sourceRevision === undefined ? {} : { sourceRevision })
    }
  } catch {
    return {}
  }
}

/// Backs agent background processes with server-owned terminals: providers
/// register mirrors in-process through the registry, and out-of-process
/// wrappers (background Bash) attach over the unix-socket host. Best-effort —
/// a host failure degrades to the plain no-terminal behavior.
export const backgroundTerminalIntegration = async (
  terminal: TerminalManagerService
): Promise<BackgroundTerminalIntegration | undefined> => {
  const registry: BackgroundTerminalIntegration["registry"] = {
    register: (key, controls) => {
      const handle = terminal.registerExternalTerminal(
        { sessionId: key, normalizeNewlines: true },
        {
          write: controls.write ?? (() => undefined),
          resize: controls.resize ?? (() => undefined),
          kill: controls.kill ?? (() => undefined),
          ...(controls.stop === undefined ? {} : { stop: controls.stop })
        }
      )
      return { output: handle.output, exit: handle.exit, remove: handle.remove }
    }
  }
  try {
    const host = await startBackgroundTerminalHost({
      registry,
      // The data dir under Application Support routinely exceeds the unix
      // socket path limit, and so does TMPDIR once a dev runner points it
      // into a deep worktree; the helper picks a location that fits.
      socketPath: backgroundTerminalSocketPath(tmpdir(), process.pid)
    })
    const runtimeDir = dirname(fileURLToPath(import.meta.url))
    return {
      registry,
      wrapCommand: wrapBackgroundCommand({
        nodePath: process.execPath,
        socketPath: host.socketPath,
        wrapperPath: join(runtimeDir, "bg-wrap.js")
      })
    }
  } catch (cause) {
    console.error(
      `Background terminal host unavailable: ${cause instanceof Error ? cause.message : String(cause)}`
    )
    return { registry }
  }
}

/// Restore saved scrollback and keep it available across graceful restarts.
export const restoreTerminalPersistence = (
  dataDir: string,
  terminal: import("@codevisor/terminal").TerminalManagerService,
  startup: StartupReporter
): void => {
  const persistence = makeTerminalPersistence({
    dataDir,
    terminal,
    log: (line) => console.log(line),
    onRestoreProgress: (completed, total) =>
      startup.work({
        id: "terminals",
        name: "Restoring saved terminals",
        completed,
        total
      })
  })
  persistence.restore()
  persistence.installExitHooks()
}

/// The `serve` arguments a self-updated runtime is re-launched with: the
/// same bind, data, identity, and auth as this process. `--boot-id` and the
/// status sidecars are deliberately absent — the new boot mints its own.
export const selfUpdateServeArgs = (options: {
  readonly host: string
  readonly port: number
  readonly databasePath: string
  readonly serverId: string
  readonly authMode: string
  readonly directPathMode: string
  readonly name: string | undefined
  readonly kind: string | undefined
}): ReadonlyArray<string> => [
  "--host",
  options.host,
  "--port",
  String(options.port),
  "--db",
  options.databasePath,
  "--serverId",
  options.serverId,
  "--auth",
  options.authMode,
  "--direct-path",
  options.directPathMode,
  ...(options.name === undefined ? [] : ["--name", options.name]),
  ...(options.kind === undefined ? [] : ["--kind", options.kind])
]

/// The terminal upgrade report for a database that could not open or
/// migrate: what the sidecar and the boot health answer carry to the app
/// and to remote clients.
export const databaseStartupFailure = (error: string): DataUpgradeProgress => ({
  state: "failed",
  id: "database-startup",
  name: "Applying update",
  completed: 0,
  total: 0,
  error
})

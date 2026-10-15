import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

import type { DataUpgradeProgress, ScreenSharingRequest } from "@codevisor/api"
import { macNativeHostAvailable, requestMacScreenSharing } from "@codevisor/automation"
import type { CodevisorDatabaseService } from "@codevisor/db"
import {
  defaultNativeConfigFileSystem,
  makeNativeMcpManager,
  type NativeMcpManager,
  type NativeMcpManagerConfig
} from "@codevisor/mcp"

import { makeCloudServerControl, startCloudBridge } from "./infra/cloud-bridge.js"
import { makeMachineEnrollment } from "./infra/machine-enrollment.js"
import { makeMachineLink } from "./infra/machine-link.js"
import { machineReleaseChannel } from "./infra/release-channel.js"
import type { ServerLease } from "./infra/server-lease.js"
import { makeTerminalPersistence } from "./infra/terminal-persistence.js"
import { systemScalerCommands, xfceScaler } from "./routes/screen-sharing-vnc-scale.js"
import { readScreenSharingVNC, vncScreenSharing } from "./routes/screen-sharing-vnc.js"
import type { ScreenSharingVNCConfig } from "./server-context-types.js"
import { makeSimulators, systemSimulatorEnvironment, type Simulators } from "./simulators.js"
import type { StartupReporter } from "./startup-progress.js"
import { field, stringField } from "./unknown-values.js"

export const SERVER_PROCESS_TITLE = "codevisor-server"
export const nativeScreenSharing = (dataDir: string) =>
  process.platform === "darwin"
    ? (request: ScreenSharingRequest) => requestMacScreenSharing(dataDir, request)
    : undefined
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
  const scaler =
    vnc.desktop === "xfce" ? xfceScaler(vnc.port - 5900, systemScalerCommands) : undefined
  return { screenSharing: vncScreenSharing(vnc, scaler), screenSharingVNC: vnc }
}
export const simulatorsProvider = (dataDir: string): Simulators | undefined =>
  process.platform === "darwin"
    ? makeSimulators(systemSimulatorEnvironment, () => macNativeHostAvailable(dataDir))
    : undefined

export const systemNativeMcpManager = (
  config: Omit<NativeMcpManagerConfig, "env" | "fs" | "homedir">
): NativeMcpManager =>
  makeNativeMcpManager({
    ...config,
    env: process.env,
    fs: defaultNativeConfigFileSystem,
    homedir: homedir()
  })
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
    const value: unknown = JSON.parse(readFileSync(metadataPath, "utf8"))
    const storedBuildNumber = field(value, "buildNumber")
    const storedSourceRevision = stringField(value, "sourceRevision")
    const buildNumber =
      typeof storedBuildNumber === "number" && Number.isSafeInteger(storedBuildNumber)
        ? storedBuildNumber
        : undefined
    const sourceRevision =
      storedSourceRevision !== undefined && storedSourceRevision.length > 0
        ? storedSourceRevision
        : undefined
    return {
      ...(buildNumber === undefined ? {} : { buildNumber }),
      ...(sourceRevision === undefined ? {} : { sourceRevision })
    }
  } catch {
    return {}
  }
}

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
  persistence.startPeriodicFlush()
}

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

export const databaseStartupFailure = (error: string): DataUpgradeProgress => ({
  state: "failed",
  id: "database-startup",
  name: "Applying update",
  completed: 0,
  total: 0,
  error
})

export const startMachineNetwork = async (options: {
  readonly databasePath: string
  readonly port: number
  readonly serverId: string
  readonly machineName: string
  readonly icon: Promise<string>
  readonly version: string | undefined
  readonly db: CodevisorDatabaseService
}) => {
  const cloudBridgeOptions = {
    credentialsPath: join(dirname(options.databasePath), "cloud.json"),
    machineName: options.machineName,
    icon: options.icon,
    serverId: options.serverId,
    appVersion: options.version ?? "unknown",
    localBaseUrl: `http://127.0.0.1:${options.port}`,
    env: process.env,
    log: (line: string) => console.error(line),
    releaseChannel: machineReleaseChannel(dirname(options.databasePath), options.db, process.env)
  }
  const cloudBridge = await initializeOptionalServerFeatureAsync("Cloud connection", async () =>
    startCloudBridge(cloudBridgeOptions)
  )
  const cloudControl = makeCloudServerControl(cloudBridgeOptions, cloudBridge)
  const machineName = (): string => cloudControl.machineName() ?? options.machineName
  const machine = {
    id: options.serverId,
    get name() {
      return machineName()
    }
  }
  const machineLink = makeMachineLink({
    self: { id: options.serverId, name: machineName, os: process.platform },
    cloud: {
      deviceId: cloudControl.deviceId,
      machines: cloudControl.machines,
      request: cloudControl.requestGateway
    },
    now: Date.now
  })
  const machineEnrollment = makeMachineEnrollment({
    cloud: cloudControl,
    link: machineLink,
    ...(process.env["CODEVISOR_INSTALL_URL"] === undefined
      ? {}
      : { installUrl: process.env["CODEVISOR_INSTALL_URL"] })
  })
  return { cloudControl, machine, machineLink, machineEnrollment }
}

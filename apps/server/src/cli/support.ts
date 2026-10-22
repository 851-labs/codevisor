import { DEFAULT_LISTEN_PORT, listenPortFile, parseListenPortFile } from "../infra/listen-port.js"
import { field, recordField, stringField } from "../unknown-values.js"
import { harnessSummaries, printRunningStatus, printUnavailableStatus } from "./status-output.js"

export interface ExecResult {
  readonly code: number
  readonly stdout: string
  readonly stderr: string
}

export interface CliDeps {
  readonly exec: (command: string, args: ReadonlyArray<string>) => Promise<ExecResult>
  readonly execInteractive: (command: string, args: ReadonlyArray<string>) => Promise<number>
  readonly spawnDetachedServer: (args: ReadonlyArray<string>, logPath: string) => Promise<number>
  readonly fetchJson: (
    url: string,
    init?: {
      readonly method?: string
      readonly body?: unknown
      readonly timeoutMs?: number
    }
  ) => Promise<{ readonly status: number; readonly body: unknown } | undefined>
  readonly readTextFile: (path: string) => string | undefined
  readonly writeTextFile: (path: string, contents: string) => void
  readonly removeFile: (path: string) => void
  readonly processAlive: (pid: number) => boolean
  readonly signal: (pid: number, signal: "SIGTERM" | "SIGKILL") => boolean
  readonly sleep: (ms: number) => Promise<void>
  readonly env: Readonly<Record<string, string | undefined>>
  readonly isRoot: boolean
  readonly installedVersion: () => string | undefined
  readonly dataDir: string
  readonly logsDir: string
  readonly log: (line: string) => void
  readonly error: (line: string) => void
}

export type ServiceManagerKind = "systemd-system" | "systemd-user" | "pidfile"

export interface ServiceManager {
  readonly kind: ServiceManagerKind
  readonly unitText?: string
}

const UNIT = "codevisor-server.service"
export const DEFAULT_PORT = DEFAULT_LISTEN_PORT

export const detectServiceManager = async (deps: CliDeps): Promise<ServiceManager> => {
  const system = await deps.exec("systemctl", ["cat", UNIT])
  if (system.code === 0) return { kind: "systemd-system", unitText: system.stdout }
  const user = await deps.exec("systemctl", ["--user", "cat", UNIT])
  if (user.code === 0) return { kind: "systemd-user", unitText: user.stdout }
  return { kind: "pidfile" }
}

export const pidFilePath = (deps: CliDeps): string => `${deps.dataDir}/server.pid`
export const logFilePath = (deps: CliDeps): string => `${deps.logsDir}/server.log`

export const resolvePort = async (
  deps: CliDeps,
  flag?: number,
  service?: ServiceManager
): Promise<number> => (await configuredPort(deps, flag, service)) ?? discoveredPort(deps)

const configuredPort = async (
  deps: CliDeps,
  flag: number | undefined,
  service: ServiceManager | undefined
): Promise<number | undefined> => {
  if (flag !== undefined) return flag
  const fromEnv = Number(deps.env["CODEVISOR_PORT"] ?? "")
  if (Number.isInteger(fromEnv) && fromEnv > 0) return fromEnv
  const detected = service ?? (await detectServiceManager(deps))
  const match = detected.unitText?.match(/--port[= ](\d+)/)
  if (match !== undefined && match !== null) return Number(match[1])
  return undefined
}

const discoveredPort = (deps: CliDeps): number =>
  parseListenPortFile(deps.readTextFile(listenPortFile(deps.dataDir))) ?? DEFAULT_PORT

const baseUrl = (port: number): string => `http://127.0.0.1:${port}`

const isAnswering = async (deps: CliDeps, port: number): Promise<boolean> => {
  const health = await deps.fetchJson(`${baseUrl(port)}/v1/health`)
  return health !== undefined && health.status === 200
}

const isHealthy = async (deps: CliDeps, port: number): Promise<boolean> => {
  const health = await deps.fetchJson(`${baseUrl(port)}/v1/health`)
  return health !== undefined && health.status === 200 && field(health.body, "ok") === true
}

const waitFor = async (
  deps: CliDeps,
  attempts: number,
  probe: () => Promise<boolean>
): Promise<boolean> => {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (await probe()) return true
    await deps.sleep(500)
  }
  return false
}

const systemctlArgs = (
  kind: "systemd-system" | "systemd-user",
  verb: string
): ReadonlyArray<string> => (kind === "systemd-user" ? ["--user", verb, UNIT] : [verb, UNIT])

const runSystemctl = async (
  deps: CliDeps,
  kind: "systemd-system" | "systemd-user",
  verb: string
): Promise<number> => {
  const result = await deps.exec("systemctl", systemctlArgs(kind, verb))
  if (result.code !== 0) {
    deps.error(result.stderr.trim().length > 0 ? result.stderr.trim() : `systemctl ${verb} failed`)
    if (kind === "systemd-system" && !deps.isRoot) {
      deps.error(`The server runs as a system service; try: sudo codevisor ${verb}`)
    }
  }
  return result.code
}

const readPid = (deps: CliDeps): number | undefined => {
  const raw = deps.readTextFile(pidFilePath(deps))
  if (raw === undefined) return undefined
  const pid = Number(raw.trim())
  return Number.isInteger(pid) && pid > 0 ? pid : undefined
}

export interface CommandOptions {
  readonly port?: number | undefined
}

export interface UpdateCommandOptions extends CommandOptions {
  readonly alpha?: boolean | undefined
}

export const startCommand = async (
  deps: CliDeps,
  options: CommandOptions = {}
): Promise<number> => {
  const service = await detectServiceManager(deps)
  const port = await resolvePort(deps, options.port, service)

  if (service.kind !== "pidfile") {
    const code = await runSystemctl(deps, service.kind, "start")
    if (code !== 0) return code
    if (!(await waitFor(deps, 60, () => isHealthy(deps, port)))) {
      deps.error(`Server did not become healthy on port ${port}; check: codevisor logs`)
      return 1
    }
    deps.log(`Codevisor server is running on port ${port}`)
    return 0
  }

  if (await isAnswering(deps, port)) {
    if (!(await waitFor(deps, 60, () => isHealthy(deps, port)))) {
      deps.error(`Server on port ${port} did not finish starting; see ${logFilePath(deps)}`)
      return 1
    }
    deps.log(`Codevisor server is already running on port ${port}`)
    return 0
  }
  const existing = readPid(deps)
  if (existing !== undefined && deps.processAlive(existing)) {
    deps.error(`A server process (pid ${existing}) exists but is not answering on port ${port}.`)
    deps.error("Stop it first: codevisor stop")
    return 1
  }
  return spawnPidfileServer(deps, await configuredPort(deps, options.port, service))
}

const spawnPidfileServer = async (deps: CliDeps, pinned: number | undefined): Promise<number> => {
  const livePort = (): number => pinned ?? discoveredPort(deps)
  const pid = await deps.spawnDetachedServer(
    [
      "serve",
      "--host",
      "0.0.0.0",
      ...(pinned === undefined ? [] : ["--port", String(pinned)]),
      "--auth",
      "token",
      "--db",
      `${deps.dataDir}/codevisor-server.sqlite`
    ],
    logFilePath(deps)
  )
  deps.writeTextFile(pidFilePath(deps), `${pid}\n`)
  if (!(await waitFor(deps, 60, () => isHealthy(deps, livePort())))) {
    deps.error(`Server did not become healthy on port ${livePort()}; see ${logFilePath(deps)}`)
    return 1
  }
  deps.log(`Codevisor server is running on port ${livePort()} (pid ${pid})`)
  return 0
}

export const stopCommand = async (deps: CliDeps, options: CommandOptions = {}): Promise<number> => {
  const service = await detectServiceManager(deps)
  if (service.kind !== "pidfile") {
    return runSystemctl(deps, service.kind, "stop")
  }

  const port = await resolvePort(deps, options.port, service)
  const pid = readPid(deps)
  if (pid !== undefined && deps.processAlive(pid)) {
    deps.signal(pid, "SIGTERM")
    if (!(await waitFor(deps, 20, () => Promise.resolve(!deps.processAlive(pid))))) {
      deps.error(`Server (pid ${pid}) did not exit after SIGTERM`)
      return 1
    }
    deps.removeFile(pidFilePath(deps))
    deps.log("Codevisor server stopped")
    return 0
  }

  if (await isAnswering(deps, port)) {
    await deps.fetchJson(`${baseUrl(port)}/v1/shutdown`, { method: "POST" })
    if (!(await waitFor(deps, 20, async () => !(await isAnswering(deps, port))))) {
      deps.error("Server is still answering after the shutdown request")
      return 1
    }
    deps.log("Codevisor server stopped")
    return 0
  }
  deps.log("Codevisor server is not running")
  return 0
}

export const restartCommand = async (
  deps: CliDeps,
  options: CommandOptions = {}
): Promise<number> => {
  const service = await detectServiceManager(deps)
  if (service.kind !== "pidfile") {
    const code = await runSystemctl(deps, service.kind, "restart")
    if (code !== 0) return code
    const port = await resolvePort(deps, options.port, service)
    if (!(await waitFor(deps, 60, () => isHealthy(deps, port)))) {
      deps.error(`Server did not become healthy on port ${port}; check: codevisor logs`)
      return 1
    }
    deps.log(`Codevisor server is running on port ${port}`)
    return 0
  }
  const stopped = await stopCommand(deps, options)
  if (stopped !== 0) return stopped
  return startCommand(deps, options)
}

export interface StatusOptions extends CommandOptions {
  readonly json?: boolean | undefined
}

export const statusCommand = async (
  deps: CliDeps,
  options: StatusOptions = {}
): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  const info = await deps.fetchJson(`${baseUrl(port)}/v1/info`)
  if (info === undefined || info.status !== 200) {
    printUnavailableStatus(deps, options, port)
    return 1
  }

  const manifest = recordField(info, "body")
  const harnesses = harnessSummaries((await deps.fetchJson(`${baseUrl(port)}/v1/harnesses`))?.body)
  printRunningStatus(deps, options, port, manifest, harnesses)
  return 0
}

export interface TokenOptions extends CommandOptions {
  readonly rotate?: boolean | undefined
}

const fetchOrRotateConnectionToken = (
  deps: CliDeps,
  port: number,
  rotate: TokenOptions["rotate"]
) => {
  if (rotate) {
    return deps.fetchJson(`${baseUrl(port)}/v1/auth/connection-token/rotate`, { method: "POST" })
  }
  return deps.fetchJson(`${baseUrl(port)}/v1/auth/connection-token`)
}

export const tokenCommand = async (deps: CliDeps, options: TokenOptions = {}): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  const response = await fetchOrRotateConnectionToken(deps, port, options.rotate)
  const okStatus = options.rotate === true ? 201 : 200
  if (response === undefined || response.status !== okStatus) {
    deps.error(`Codevisor server is not running on port ${port}; start it first: codevisor start`)
    return 1
  }
  const token = stringField(response.body, "token")
  /* v8 ignore next 4 */
  if (token === undefined) {
    deps.error("Server did not return a token")
    return 1
  }
  deps.log(token)
  return 0
}

export const updateCommand = async (
  deps: CliDeps,
  options: UpdateCommandOptions = {}
): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  const channelQuery = options.alpha === true ? "&channel=alpha" : ""
  const updateURL = `${baseUrl(port)}/v1/update?refresh=1${channelQuery}`
  const update = await deps.fetchJson(updateURL)
  if (update === undefined || update.status !== 200) {
    deps.error(`Codevisor server is not running on port ${port}.`)
    deps.error("Start it (codevisor start) or re-run the install script to update in place.")
    return 1
  }
  const state = {
    updateAvailable: field(update.body, "updateAvailable"),
    currentVersion: stringField(update.body, "currentVersion"),
    latestVersion: stringField(update.body, "latestVersion")
  }
  if (state.updateAvailable !== true) {
    deps.log(`Already up to date (${state.currentVersion ?? "unknown version"})`)
    return 0
  }
  deps.log(`Updating ${state.currentVersion ?? "?"} → ${state.latestVersion ?? "?"}`)
  const initialHealth = await deps.fetchJson(`${baseUrl(port)}/v1/health`)
  const initialBootId = stringField(initialHealth?.body, "bootId")
  const applyURL = `${baseUrl(port)}/v1/update/apply${options.alpha === true ? "?channel=alpha" : ""}`
  const apply = await deps.fetchJson(applyURL, { method: "POST" })
  const accepted = field(apply?.body, "accepted")
  if (apply === undefined || accepted !== true) {
    deps.error("Server declined the update (a chat may be mid-turn); retry shortly")
    return 1
  }
  const updated = await waitFor(deps, 240, async () => {
    const info = await deps.fetchJson(`${baseUrl(port)}/v1/info`)
    const version = stringField(info?.body, "version")
    if (info === undefined || info.status !== 200) return false
    if (version === state.latestVersion) return true

    const health = await deps.fetchJson(`${baseUrl(port)}/v1/health`)
    const bootId = stringField(health?.body, "bootId")
    const restarted =
      (initialBootId !== undefined && bootId !== undefined && bootId !== initialBootId) ||
      (state.currentVersion !== undefined && version !== state.currentVersion)
    if (!restarted) return false
    const refreshed = await deps.fetchJson(updateURL)
    return (
      refreshed !== undefined &&
      refreshed.status === 200 &&
      field(refreshed.body, "updateAvailable") === false
    )
  })
  if (!updated) {
    deps.error("Timed out waiting for the updated server; check: codevisor logs")
    return 1
  }
  deps.log(`Codevisor server updated to ${state.latestVersion}`)
  return 0
}

export interface LogsOptions {
  readonly follow?: boolean
}

export const logsCommand = async (deps: CliDeps, options: LogsOptions = {}): Promise<number> => {
  const service = await detectServiceManager(deps)
  const follow = options.follow === true
  if (service.kind !== "pidfile") {
    const args = [
      ...(service.kind === "systemd-user" ? ["--user"] : []),
      "-u",
      UNIT,
      "-n",
      "100",
      ...(follow ? ["-f"] : [])
    ]
    return deps.execInteractive("journalctl", args)
  }
  const path = logFilePath(deps)
  if (deps.readTextFile(path) === undefined) {
    deps.error(`No log file at ${path}`)
    return 1
  }
  return deps.execInteractive("tail", ["-n", "100", ...(follow ? ["-f"] : []), path])
}

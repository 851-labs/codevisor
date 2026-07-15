/// Logic behind the `codevisor` CLI, written against an injectable `CliDeps`
/// seam so every command is unit-testable without touching systemctl, the
/// network, or the process table. The real Node-backed deps live in cli.ts.

export interface ExecResult {
  readonly code: number
  readonly stdout: string
  readonly stderr: string
}

export interface CliDeps {
  /// Run a command to completion, capturing output. Spawn failures (missing
  /// binary) surface as a non-zero code, never a rejection.
  readonly exec: (command: string, args: ReadonlyArray<string>) => Promise<ExecResult>
  /// Run a command wired to this terminal (journalctl -f, tail -f). Resolves
  /// with the exit code once the child ends.
  readonly execInteractive: (command: string, args: ReadonlyArray<string>) => Promise<number>
  /// Spawn a detached `codevisor-server serve …` appending output to logPath;
  /// resolves with the child pid.
  readonly spawnDetachedServer: (args: ReadonlyArray<string>, logPath: string) => Promise<number>
  /// JSON request against the loopback API. `undefined` when the server is
  /// unreachable (connection refused / timeout).
  readonly fetchJson: (
    url: string,
    init?: { readonly method?: string }
  ) => Promise<{ readonly status: number; readonly body: unknown } | undefined>
  readonly readTextFile: (path: string) => string | undefined
  readonly writeTextFile: (path: string, contents: string) => void
  readonly removeFile: (path: string) => void
  readonly processAlive: (pid: number) => boolean
  readonly signal: (pid: number, signal: "SIGTERM" | "SIGKILL") => boolean
  readonly sleep: (ms: number) => Promise<void>
  readonly env: Readonly<Record<string, string | undefined>>
  readonly isRoot: boolean
  /// Version stamped into the installed runtime (the VERSION file), if any.
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
export const DEFAULT_PORT = 49361

/// systemd owns the server when a unit exists (install.sh sets one up); the
/// pidfile fallback covers macOS standalone runs and CODEVISOR_NO_SERVICE
/// installs.
export const detectServiceManager = async (deps: CliDeps): Promise<ServiceManager> => {
  const system = await deps.exec("systemctl", ["cat", UNIT])
  if (system.code === 0) return { kind: "systemd-system", unitText: system.stdout }
  const user = await deps.exec("systemctl", ["--user", "cat", UNIT])
  if (user.code === 0) return { kind: "systemd-user", unitText: user.stdout }
  return { kind: "pidfile" }
}

export const pidFilePath = (deps: CliDeps): string => `${deps.dataDir}/server.pid`
export const logFilePath = (deps: CliDeps): string => `${deps.logsDir}/server.log`

/// --port flag > CODEVISOR_PORT > the systemd unit's ExecStart > default.
export const resolvePort = async (
  deps: CliDeps,
  flag?: number,
  service?: ServiceManager
): Promise<number> => {
  if (flag !== undefined) return flag
  const fromEnv = Number(deps.env["CODEVISOR_PORT"] ?? "")
  if (Number.isInteger(fromEnv) && fromEnv > 0) return fromEnv
  const detected = service ?? (await detectServiceManager(deps))
  const match = detected.unitText?.match(/--port[= ](\d+)/)
  if (match !== undefined && match !== null) return Number(match[1])
  return DEFAULT_PORT
}

const baseUrl = (port: number): string => `http://127.0.0.1:${port}`

const isHealthy = async (deps: CliDeps, port: number): Promise<boolean> => {
  const health = await deps.fetchJson(`${baseUrl(port)}/v1/health`)
  return health !== undefined && health.status === 200
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

  if (await isHealthy(deps, port)) {
    deps.log(`Codevisor server is already running on port ${port}`)
    return 0
  }
  const existing = readPid(deps)
  if (existing !== undefined && deps.processAlive(existing)) {
    deps.error(`A server process (pid ${existing}) exists but is not answering on port ${port}.`)
    deps.error("Stop it first: codevisor stop")
    return 1
  }
  const pid = await deps.spawnDetachedServer(
    [
      "serve",
      "--host",
      "0.0.0.0",
      "--port",
      String(port),
      "--auth",
      "token",
      "--db",
      `${deps.dataDir}/codevisor-server.sqlite`
    ],
    logFilePath(deps)
  )
  deps.writeTextFile(pidFilePath(deps), `${pid}\n`)
  if (!(await waitFor(deps, 60, () => isHealthy(deps, port)))) {
    deps.error(`Server did not become healthy on port ${port}; see ${logFilePath(deps)}`)
    return 1
  }
  deps.log(`Codevisor server is running on port ${port} (pid ${pid})`)
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

  // No pidfile (or a stale one): fall back to asking a live server politely.
  if (await isHealthy(deps, port)) {
    await deps.fetchJson(`${baseUrl(port)}/v1/shutdown`, { method: "POST" })
    if (!(await waitFor(deps, 20, async () => !(await isHealthy(deps, port))))) {
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

interface HarnessSummary {
  readonly id: string
  readonly state: string
  readonly detail?: string
  readonly version?: string
  readonly path?: string
}

const harnessSummaries = (body: unknown): ReadonlyArray<HarnessSummary> => {
  if (!Array.isArray(body)) return []
  return body.flatMap((entry) => {
    if (typeof entry !== "object" || entry === null) return []
    const harness = entry as {
      readonly id?: string
      readonly readiness?: {
        readonly state?: string
        readonly detail?: string
        readonly version?: string
        readonly path?: string
      }
    }
    if (typeof harness.id !== "string") return []
    const readiness = harness.readiness
    return [
      {
        id: harness.id,
        state: readiness?.state ?? "unknown",
        ...(readiness?.detail === undefined ? {} : { detail: readiness.detail }),
        ...(readiness?.version === undefined ? {} : { version: readiness.version }),
        ...(readiness?.path === undefined ? {} : { path: readiness.path })
      }
    ]
  })
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
    if (options.json === true) {
      deps.log(
        JSON.stringify({ running: false, port, installedVersion: deps.installedVersion() ?? null })
      )
    } else {
      deps.log(`Codevisor server is not running on port ${port}`)
      const installed = deps.installedVersion()
      if (installed !== undefined) deps.log(`Installed version: ${installed}`)
      deps.log("Start it with: codevisor start")
    }
    return 1
  }

  const manifest = info.body as Record<string, unknown>
  const harnesses = harnessSummaries((await deps.fetchJson(`${baseUrl(port)}/v1/harnesses`))?.body)
  if (options.json === true) {
    deps.log(
      JSON.stringify({
        running: true,
        port,
        name: manifest.name,
        version: manifest.version,
        serverId: manifest.id,
        machineId: manifest.machineId,
        platform: manifest.platform,
        arch: manifest.arch,
        hostname: manifest.hostname,
        harnesses
      })
    )
    return 0
  }
  deps.log(`Codevisor server ${String(manifest.version)} is running on port ${port}`)
  deps.log(`  name:      ${String(manifest.name)}`)
  deps.log(
    `  machine:   ${String(manifest.hostname ?? "unknown")} (${String(manifest.machineId ?? "unknown")})`
  )
  deps.log(`  platform:  ${String(manifest.platform)}/${String(manifest.arch ?? "unknown")}`)
  if (harnesses.length > 0) {
    deps.log("  harnesses:")
    for (const harness of harnesses) {
      const version = harness.version === undefined ? "" : ` ${harness.version}`
      const location = harness.path === undefined ? "" : ` (${harness.path})`
      const detail = harness.detail === undefined ? "" : ` — ${harness.detail}`
      deps.log(`    ${harness.id}: ${harness.state}${version}${location}${detail}`)
    }
  }
  return 0
}

export interface TokenOptions extends CommandOptions {
  /// Replace the token, retiring the old one (clients must re-pair).
  readonly rotate?: boolean | undefined
}

export const tokenCommand = async (deps: CliDeps, options: TokenOptions = {}): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  // The connection token is stable across restarts and updates; `--rotate`
  // issues a fresh one and invalidates the previous.
  const response = options.rotate
    ? await deps.fetchJson(`${baseUrl(port)}/v1/auth/connection-token/rotate`, { method: "POST" })
    : await deps.fetchJson(`${baseUrl(port)}/v1/auth/connection-token`)
  const okStatus = options.rotate === true ? 201 : 200
  if (response === undefined || response.status !== okStatus) {
    deps.error(`Codevisor server is not running on port ${port}; start it first: codevisor start`)
    return 1
  }
  const token = (response.body as { readonly token?: string }).token
  /* v8 ignore next 4 -- the server always returns a token with a success status. */
  if (token === undefined) {
    deps.error("Server did not return a token")
    return 1
  }
  deps.log(token)
  return 0
}

export const updateCommand = async (
  deps: CliDeps,
  options: CommandOptions = {}
): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  const update = await deps.fetchJson(`${baseUrl(port)}/v1/update`)
  if (update === undefined || update.status !== 200) {
    deps.error(`Codevisor server is not running on port ${port}.`)
    deps.error("Start it (codevisor start) or re-run the install script to update in place.")
    return 1
  }
  const state = update.body as {
    readonly updateAvailable?: boolean
    readonly currentVersion?: string
    readonly latestVersion?: string
  }
  if (state.updateAvailable !== true) {
    deps.log(`Already up to date (${state.currentVersion ?? "unknown version"})`)
    return 0
  }
  deps.log(`Updating ${state.currentVersion ?? "?"} → ${state.latestVersion ?? "?"}`)
  const apply = await deps.fetchJson(`${baseUrl(port)}/v1/update/apply`, { method: "POST" })
  const accepted = (apply?.body as { readonly accepted?: boolean } | undefined)?.accepted
  if (apply === undefined || accepted !== true) {
    deps.error("Server declined the update (a chat may be mid-turn); retry shortly")
    return 1
  }
  const updated = await waitFor(deps, 240, async () => {
    const info = await deps.fetchJson(`${baseUrl(port)}/v1/info`)
    const version = (info?.body as { readonly version?: string } | undefined)?.version
    return info !== undefined && info.status === 200 && version === state.latestVersion
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

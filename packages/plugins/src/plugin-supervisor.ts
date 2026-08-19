import type { PluginRuntimeState } from "@codevisor/api"
import { spawn } from "node:child_process"
import { mkdirSync } from "node:fs"
import { connect, createServer } from "node:net"
import { join } from "node:path"
import type { InstalledPlugin } from "./plugin-store.js"
import { PluginsError } from "./plugins-error.js"

/// Minimal handle the supervisor needs over a plugin child process.
/// Production uses defaultSpawnShell; tests inject fakes that bind the
/// assigned port in-process.
export interface PluginProcessHandle {
  readonly pid: number | undefined
  readonly kill: () => void
  /// `exitCode` is the numeric process exit status when the spawner knows it
  /// (null for signal deaths and launch failures). The supervisor only needs
  /// the message; the install pipeline needs the code to gate success.
  readonly onExit: (listener: (message: string, exitCode?: number | null) => void) => void
  /// Combined stdout/stderr stream, when the spawner can provide one. Feeds
  /// the observability terminal ("Show Output"); optional so test fakes stay
  /// tiny.
  readonly onOutput?: (listener: (data: string) => void) => void
}

export interface PluginSpawnOptions {
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
}

/// Structural mirror of packages/terminal's external-terminal surface, so
/// plugin output can stream into an attachable terminal without this package
/// depending on @codevisor/terminal. The real
/// TerminalManagerService.registerExternalTerminal satisfies
/// RegisterPluginTerminal as-is.
export interface PluginTerminalProcess {
  readonly write: (data: string) => void
  readonly resize: (cols: number, rows: number) => void
  readonly kill: () => void
}

export interface PluginTerminalHandle {
  readonly terminalId: string
  readonly output: (data: string) => void
  readonly exit: (exitCode?: number) => void
}

export interface PluginTerminalConfig {
  readonly sessionId: string
  readonly normalizeNewlines?: boolean
}

export type RegisterPluginTerminal = (
  config: PluginTerminalConfig,
  process: PluginTerminalProcess
) => PluginTerminalHandle

export interface PluginSupervisorConfig {
  /// Root for per-plugin writable state (CODEVISOR_PLUGIN_DATA_DIR).
  readonly dataDir: string
  readonly spawnShell?: (command: string, options: PluginSpawnOptions) => PluginProcessHandle
  /// Login-shell environment for spawns; defaults to process.env.
  readonly resolveEnv?: () => Promise<NodeJS.ProcessEnv>
  readonly log?: (message: string) => void
  /// How long a plugin gets from spawn to accepting connections.
  readonly readyTimeoutMs?: number
  readonly now?: () => number
  /// Crash/restart circuit breaker: after this many consecutive failures
  /// without a successful request in between, the plugin is refused until an
  /// explicit stop/restart. Default 5.
  readonly maxConsecutiveFailures?: number
  /// First restart-backoff window after a crash; doubles per consecutive
  /// failure. Default 500ms.
  readonly backoffBaseMs?: number
  /// Backoff ceiling. Default 30s.
  readonly backoffCapMs?: number
  /// Observes every runtime state transition (fed into the server's event
  /// fanout as plugin.state.updated).
  readonly onStateChange?: (pluginId: string, state: PluginRuntimeState) => void
  /// When present, each plugin process's output streams into an attachable
  /// external terminal (sessionId `plugin:{pluginId}`) so clients can offer
  /// "Show Output".
  readonly registerExternalTerminal?: RegisterPluginTerminal
}

interface RunningPlugin {
  state: PluginRuntimeState
  port?: number
  process?: PluginProcessHandle
  startPromise?: Promise<number>
  /// Idle-shutdown clock: last proxied request (or WS release) timestamp.
  lastActivityAt: number
  /// Open WebSocket splices pin the process alive; the idle clock only runs
  /// at zero.
  pins: number
  idleTimer?: NodeJS.Timeout
  /// Captured from the manifest at start time (ms; 0 = never idle out).
  idleTimeoutMs: number
  /// Consecutive failed starts/crashes since the last successful request.
  failures: number
  /// Restart-backoff gate: ensureRunning refuses before this timestamp.
  notBefore: number
}

export interface PluginSupervisor {
  /// Lazily starts the plugin's server if needed and resolves its loopback
  /// port. Concurrent callers share one start attempt. Refuses while the
  /// crash circuit breaker is tripped or inside a restart-backoff window.
  readonly ensureRunning: (plugin: InstalledPlugin) => Promise<number>
  readonly state: (pluginId: string) => PluginRuntimeState
  /// A proxied request completed successfully: resets the idle clock and the
  /// crash circuit breaker.
  readonly noteSuccess: (pluginId: string) => void
  /// Pins the process alive for the lifetime of a WebSocket splice; the
  /// returned release is idempotent and restarts the idle clock.
  readonly pin: (pluginId: string) => () => void
  /// The proxy found the plugin's port dead while the supervisor thought it
  /// was running: treat it as a crash so the next request relaunches instead
  /// of hitting a dead port forever.
  readonly markUnreachable: (pluginId: string) => void
  /// Stop + clear failure state; the next request starts fresh.
  readonly restart: (pluginId: string) => void
  readonly stop: (pluginId: string) => void
  readonly closeAll: () => void
}

export const DEFAULT_IDLE_TIMEOUT_SECONDS = 300

/// A crashed or killed plugin must never take the server with it: every
/// stream gets an error listener from construction (stdio-transport
/// invariant) and exits only flip supervisor state. Exported so the install
/// pipeline runs manifest install commands through the same login-shell
/// runner (with the same seam for tests).
export const defaultSpawnShell = (
  command: string,
  options: PluginSpawnOptions
): PluginProcessHandle => {
  /* v8 ignore next -- SHELL is always set in practice; /bin/sh is the documented fallback. */
  const shell = process.env["SHELL"] ?? "/bin/sh"
  const child = spawn(shell, ["-lc", command], {
    cwd: options.cwd,
    detached: process.platform !== "win32",
    env: options.env,
    stdio: ["ignore", "pipe", "pipe"]
  })
  const stderrTail: Array<string> = []
  const outputListeners: Array<(data: string) => void> = []
  const forward = (chunk: Buffer): void => {
    const data = chunk.toString("utf8")
    for (const listener of outputListeners) {
      listener(data)
    }
  }
  /* v8 ignore next -- defensive: an unhandled stream error is process-fatal (stdio-transport invariant). */
  child.stdout?.on("error", () => undefined)
  /* v8 ignore next -- defensive: an unhandled stream error is process-fatal (stdio-transport invariant). */
  child.stderr?.on("error", () => undefined)
  child.stdout?.on("data", forward)
  child.stderr?.on("data", (chunk: Buffer) => {
    stderrTail.push(chunk.toString("utf8"))
    forward(chunk)
  })
  const exitListeners: Array<(message: string, exitCode?: number | null) => void> = []
  child.on("error", (cause) => {
    for (const listener of exitListeners) {
      listener(`Failed to launch plugin process: ${cause.message}`, null)
    }
  })
  child.on("exit", (code, signal) => {
    const reason = signal === null ? `exited with code ${code}` : `terminated by ${signal}`
    const tail = stderrTail.slice(-20).join("").trim()
    for (const listener of exitListeners) {
      listener(tail.length === 0 ? reason : `${reason}\n${tail.slice(-2000)}`, code)
    }
  })
  return {
    kill: () => {
      /* v8 ignore start -- process-group kill paths depend on platform state. */
      const pid = child.pid
      if (pid === undefined) {
        return
      }
      try {
        // The run command is a shell line; kill the whole group so the
        // plugin's own children die with it.
        process.kill(-pid, "SIGTERM")
      } catch {
        child.kill("SIGTERM")
      }
      /* v8 ignore stop */
    },
    onExit: (listener) => {
      exitListeners.push(listener)
    },
    onOutput: (listener) => {
      outputListeners.push(listener)
    },
    pid: child.pid
  }
}

/// Asks the kernel for a free loopback port. A race against another process
/// binding it before the plugin does is possible but harmless: startup fails
/// readiness and surfaces as a plugin error, never a hijack (the plugin binds
/// loopback).
const allocatePort = (): Promise<number> =>
  new Promise((resolve, reject) => {
    const probe = createServer()
    /* v8 ignore next -- loopback ephemeral binds only fail under fd exhaustion. */
    probe.once("error", reject)
    probe.listen(0, "127.0.0.1", () => {
      const address = probe.address()
      /* v8 ignore next -- TCP listen always returns AddressInfo here. */
      const port = typeof address === "object" && address !== null ? address.port : 0
      probe.close(() => resolve(port))
    })
  })

const tcpProbe = (port: number): Promise<boolean> =>
  new Promise((resolve) => {
    const socket = connect({ host: "127.0.0.1", port })
    const done = (up: boolean): void => {
      socket.destroy()
      resolve(up)
    }
    socket.once("connect", () => done(true))
    socket.once("error", () => done(false))
    /* v8 ignore next -- loopback connects resolve or error immediately. */
    socket.setTimeout(1_000, () => done(false))
  })

const delay = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms))

export const makePluginSupervisor = (config: PluginSupervisorConfig): PluginSupervisor => {
  const runtimes = new Map<string, RunningPlugin>()
  const log = config.log ?? (() => undefined)
  const readyTimeoutMs = config.readyTimeoutMs ?? 15_000
  const now = config.now ?? Date.now
  const spawnShell = config.spawnShell ?? defaultSpawnShell
  const maxConsecutiveFailures = config.maxConsecutiveFailures ?? 5
  const backoffBaseMs = config.backoffBaseMs ?? 500
  const backoffCapMs = config.backoffCapMs ?? 30_000

  const runtime = (pluginId: string): RunningPlugin => {
    const existing = runtimes.get(pluginId)
    if (existing !== undefined) {
      return existing
    }
    const created: RunningPlugin = {
      failures: 0,
      idleTimeoutMs: 0,
      lastActivityAt: 0,
      notBefore: 0,
      pins: 0,
      state: "stopped"
    }
    runtimes.set(pluginId, created)
    return created
  }

  const setState = (pluginId: string, current: RunningPlugin, state: PluginRuntimeState): void => {
    if (current.state === state) {
      return
    }
    current.state = state
    config.onStateChange?.(pluginId, state)
  }

  const clearIdleTimer = (current: RunningPlugin): void => {
    if (current.idleTimer !== undefined) {
      clearTimeout(current.idleTimer)
      delete current.idleTimer
    }
  }

  const clearProcess = (current: RunningPlugin): void => {
    clearIdleTimer(current)
    delete current.port
    delete current.process
  }

  /// One crash or failed start: arm the exponential-backoff window and pick
  /// the next state — `failed` once the circuit breaker trips, `stopped`
  /// while restarts are still allowed.
  const registerFailure = (current: RunningPlugin): PluginRuntimeState => {
    current.failures += 1
    current.notBefore = now() + Math.min(backoffBaseMs * 2 ** (current.failures - 1), backoffCapMs)
    clearProcess(current)
    return current.failures >= maxConsecutiveFailures ? "failed" : "stopped"
  }

  /// Idle shutdown: one unref'd timer per running plugin, re-armed until the
  /// last activity is older than the idle window and no WS splice pins the
  /// process.
  const armIdleTimer = (
    pluginId: string,
    current: RunningPlugin,
    child: PluginProcessHandle
  ): void => {
    clearIdleTimer(current)
    if (current.idleTimeoutMs <= 0) {
      return
    }
    // While pinned the clock is parked (recheck a full window later);
    // otherwise fire when the last activity ages past the window. A slightly
    // negative remainder just fires immediately and rechecks.
    const remaining =
      current.pins > 0
        ? current.idleTimeoutMs
        : current.lastActivityAt + current.idleTimeoutMs - now()
    const timer = setTimeout(() => {
      delete current.idleTimer
      /* v8 ignore next 3 -- a stop landing between timer fire and callback dispatch leaves nothing to do. */
      if (current.state !== "running" || current.process !== child) {
        return
      }
      if (current.pins > 0 || now() - current.lastActivityAt < current.idleTimeoutMs) {
        armIdleTimer(pluginId, current, child)
        return
      }
      log(`Plugin ${pluginId} idle for ${current.idleTimeoutMs}ms; stopping`)
      child.kill()
      clearProcess(current)
      setState(pluginId, current, "stopped")
    }, remaining)
    timer.unref()
    current.idleTimer = timer
  }

  const start = async (plugin: InstalledPlugin, current: RunningPlugin): Promise<number> => {
    const port = await allocatePort()
    const dataDir = join(config.dataDir, plugin.id)
    mkdirSync(dataDir, { recursive: true })
    const env: NodeJS.ProcessEnv = {
      ...(await (config.resolveEnv?.() ?? Promise.resolve(process.env))),
      CODEVISOR_PLUGIN_DATA_DIR: dataDir,
      CODEVISOR_PLUGIN_ID: plugin.id,
      PORT: String(port)
    }
    let exitMessage: string | undefined
    const child = spawnShell(plugin.manifest.run.command, { cwd: plugin.path, env })
    // A restart re-registers under the same session key, replacing the old
    // terminal, so "Show Output" always shows the live process.
    const terminal = config.registerExternalTerminal?.(
      { normalizeNewlines: true, sessionId: `plugin:${plugin.id}` },
      { kill: () => child.kill(), resize: () => undefined, write: () => undefined }
    )
    if (terminal !== undefined) {
      terminal.output(`$ ${plugin.manifest.run.command}\r\n`)
      child.onOutput?.((data) => terminal.output(data))
    }
    child.onExit((message) => {
      exitMessage = message
      terminal?.exit()
      const state = runtime(plugin.id)
      // Exits during startup are consumed by the readiness loop; superseded
      // processes (stop/restart already cleared them) only close their
      // terminal. Only an unexpected exit of the live process is a crash.
      if (state.process === child && state.state === "running") {
        log(`Plugin ${plugin.id} ${message.split("\n")[0]}`)
        setState(plugin.id, state, registerFailure(state))
      }
    })
    current.process = child
    const deadline = now() + readyTimeoutMs
    while (now() < deadline) {
      if (exitMessage !== undefined) {
        throw new PluginsError("invalid", `Plugin ${plugin.id} ${exitMessage}`)
      }
      if (await tcpProbe(port)) {
        current.port = port
        current.idleTimeoutMs =
          (plugin.manifest.idleTimeoutSeconds ?? DEFAULT_IDLE_TIMEOUT_SECONDS) * 1_000
        current.lastActivityAt = now()
        setState(plugin.id, current, "running")
        armIdleTimer(plugin.id, current, child)
        log(`Plugin ${plugin.id} listening on 127.0.0.1:${port}`)
        return port
      }
      await delay(150)
    }
    child.kill()
    throw new PluginsError(
      "invalid",
      `Plugin ${plugin.id} did not start listening on $PORT within ${readyTimeoutMs}ms`
    )
  }

  const stop = (pluginId: string): void => {
    const current = runtimes.get(pluginId)
    if (current === undefined) {
      return
    }
    // Explicit stop/restart clears the crash accounting: the next request
    // starts fresh with no backoff and an open circuit breaker.
    current.failures = 0
    current.notBefore = 0
    if (current.state === "stopped") {
      return
    }
    setState(pluginId, current, "stopping")
    current.process?.kill()
    clearProcess(current)
    setState(pluginId, current, "stopped")
  }

  return {
    closeAll: () => {
      for (const [pluginId, current] of runtimes) {
        current.process?.kill()
        clearProcess(current)
        current.failures = 0
        current.notBefore = 0
        setState(pluginId, current, "stopped")
      }
    },
    ensureRunning: async (plugin) => {
      const current = runtime(plugin.id)
      current.lastActivityAt = now()
      if (current.state === "running" && current.port !== undefined) {
        return current.port
      }
      if (current.startPromise !== undefined) {
        return current.startPromise
      }
      if (current.failures >= maxConsecutiveFailures) {
        throw new PluginsError(
          "unavailable",
          `Plugin ${plugin.id} failed ${current.failures} times in a row; restart it to try again`
        )
      }
      const backoffRemainingMs = current.notBefore - now()
      if (backoffRemainingMs > 0) {
        throw new PluginsError(
          "unavailable",
          `Plugin ${plugin.id} recently crashed; retry in ${backoffRemainingMs}ms`
        )
      }
      setState(plugin.id, current, "starting")
      const startPromise = start(plugin, current).catch((cause: unknown) => {
        registerFailure(current)
        // A start that never came up is always `failed` (the breaker decides
        // only whether retries are still allowed).
        setState(plugin.id, current, "failed")
        throw cause
      })
      current.startPromise = startPromise
      try {
        return await startPromise
      } finally {
        delete current.startPromise
      }
    },
    markUnreachable: (pluginId) => {
      const current = runtimes.get(pluginId)
      if (current === undefined || current.state !== "running") {
        return
      }
      log(`Plugin ${pluginId} stopped answering on 127.0.0.1:${current.port}; treating as crashed`)
      /* v8 ignore next -- a running runtime always tracks its process. */
      current.process?.kill()
      setState(pluginId, current, registerFailure(current))
    },
    noteSuccess: (pluginId) => {
      const current = runtimes.get(pluginId)
      if (current === undefined) {
        return
      }
      current.lastActivityAt = now()
      current.failures = 0
      current.notBefore = 0
    },
    pin: (pluginId) => {
      const current = runtime(pluginId)
      current.pins += 1
      let released = false
      return () => {
        if (released) {
          return
        }
        released = true
        current.pins -= 1
        current.lastActivityAt = now()
      }
    },
    restart: (pluginId) => stop(pluginId),
    state: (pluginId) => runtimes.get(pluginId)?.state ?? "stopped",
    stop
  }
}

import { spawn } from "node:child_process"
import { mkdirSync } from "node:fs"
import { join } from "node:path"

import type { PluginRuntimeState } from "@codevisor/api"

import { displayPluginCommand, pluginRunCommand } from "./plugin-command.js"
import { allocatePort, tcpProbe, httpProbe } from "./plugin-readiness.js"
import type { InstalledPlugin } from "./plugin-store.js"
import { PluginsError } from "./plugins-error.js"

export interface PluginProcessHandle {
  readonly pid: number | undefined
  readonly kill: () => void
  readonly onExit: (listener: (message: string, exitCode?: number | null) => void) => void
  readonly onOutput?: (listener: (data: string) => void) => void
}

export interface PluginSpawnOptions {
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
}

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
  readonly dataDir: string
  readonly spawnShell?: (command: string, options: PluginSpawnOptions) => PluginProcessHandle
  readonly spawnArgv?: (
    argv: ReadonlyArray<string>,
    options: PluginSpawnOptions
  ) => PluginProcessHandle
  readonly contextSecret?: (pluginId: string) => string
  readonly resolveEnv?: () => Promise<NodeJS.ProcessEnv>
  readonly log?: (message: string) => void
  readonly now?: () => number
  readonly sleep?: (ms: number) => Promise<void>
  readonly maxConsecutiveFailures?: number
  readonly onStateChange?: (pluginId: string, state: PluginRuntimeState) => void
  readonly onUnexpectedExit?: (pluginId: string) => void
  readonly registerExternalTerminal?: RegisterPluginTerminal
}

interface RunningPlugin {
  generation: number
  state: PluginRuntimeState
  port?: number
  process?: PluginProcessHandle
  startPromise?: Promise<PluginLease>
  lease?: PluginLease
  failures: number
  runningSince?: number
  notBefore: number
}

export interface PluginSupervisor {
  readonly acquire: (plugin: InstalledPlugin) => Promise<PluginLease>
  readonly ensureRunning: (plugin: InstalledPlugin) => Promise<number>
  readonly state: (pluginId: string) => PluginRuntimeState
  readonly noteSuccess: (pluginId: string, lease: PluginLease) => void
  readonly markUnreachable: (pluginId: string, lease: PluginLease) => void
  readonly restart: (pluginId: string) => void
  readonly stop: (pluginId: string) => void
  readonly closeAll: () => void
}

export interface PluginLease {
  readonly port: number
}

export const defaultSpawnShell = (
  command: string,
  options: PluginSpawnOptions
): PluginProcessHandle =>
  spawnPluginProcess(
    /* v8 ignore next */
    options.env["SHELL"] ?? process.env["SHELL"] ?? "/bin/sh",
    ["-lc", command],
    options
  )

export const defaultSpawnArgv = (
  argv: ReadonlyArray<string>,
  options: PluginSpawnOptions
): PluginProcessHandle => {
  const [executable, ...args] = argv
  /* v8 ignore next */
  return spawnPluginProcess(executable ?? "", args, options)
}

const spawnPluginProcess = (
  executable: string,
  args: ReadonlyArray<string>,
  options: PluginSpawnOptions
): PluginProcessHandle => {
  const child = spawn(executable, args, {
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
  /* v8 ignore next */
  child.stdout?.on("error", () => undefined)
  /* v8 ignore next */
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
      /* v8 ignore start */
      const pid = child.pid
      if (pid === undefined) {
        return
      }
      try {
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

const READY_TIMEOUT_MS = 15_000
const BACKOFF_BASE_MS = 500
const BACKOFF_CAP_MS = 30_000
const STABLE_RUNTIME_MS = 30_000

const delay = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms))

const clearProcess = (current: RunningPlugin): void => {
  delete current.lease
  delete current.port
  delete current.process
  delete current.runningSince
}

export const makePluginSupervisor = (config: PluginSupervisorConfig): PluginSupervisor => {
  const runtimes = new Map<string, RunningPlugin>()
  const log = config.log ?? (() => undefined)
  const now = config.now ?? Date.now
  const sleep = config.sleep ?? delay
  const spawnShell = config.spawnShell ?? defaultSpawnShell
  const spawnArgv = config.spawnArgv ?? defaultSpawnArgv
  const maxConsecutiveFailures = config.maxConsecutiveFailures ?? 5

  const runtime = (pluginId: string): RunningPlugin => {
    const existing = runtimes.get(pluginId)
    if (existing !== undefined) {
      return existing
    }
    const created: RunningPlugin = {
      generation: 0,
      failures: 0,
      notBefore: 0,
      state: "stopped"
    }
    runtimes.set(pluginId, created)
    return created
  }

  const setState = (pluginId: string, current: RunningPlugin, state: PluginRuntimeState): void => {
    current.state = state
    config.onStateChange?.(pluginId, state)
  }

  const registerFailure = (current: RunningPlugin): PluginRuntimeState => {
    if (current.runningSince !== undefined && now() - current.runningSince >= STABLE_RUNTIME_MS) {
      current.failures = 0
    }
    current.failures += 1
    current.notBefore =
      now() + Math.min(BACKOFF_BASE_MS * 2 ** (current.failures - 1), BACKOFF_CAP_MS)
    clearProcess(current)
    return current.failures >= maxConsecutiveFailures ? "failed" : "stopped"
  }

  const start = async (
    plugin: InstalledPlugin,
    current: RunningPlugin,
    generation: number
  ): Promise<PluginLease> => {
    const checkOwner = (): void => {
      if (current.generation !== generation)
        throw new PluginsError("unavailable", `Plugin ${plugin.id} startup was stopped`)
    }
    const port = await allocatePort()
    checkOwner()
    const dataDir = join(config.dataDir, plugin.id)
    mkdirSync(dataDir, { recursive: true })
    const env: NodeJS.ProcessEnv = {
      ...(await (config.resolveEnv?.() ?? Promise.resolve(process.env))),
      ...(config.contextSecret === undefined
        ? {}
        : { CODEVISOR_PLUGIN_CONTEXT_SECRET: config.contextSecret(plugin.id) }),
      CODEVISOR_PLUGIN_DATA_DIR: dataDir,
      CODEVISOR_PLUGIN_ID: plugin.id,
      PORT: String(port)
    }
    checkOwner()
    let exitMessage: string | undefined
    const runCommand = pluginRunCommand(plugin.manifest)
    const child =
      runCommand.kind === "shell"
        ? spawnShell(runCommand.command, { cwd: plugin.path, env })
        : spawnArgv(runCommand.argv, { cwd: plugin.path, env })
    const terminal = config.registerExternalTerminal?.(
      { normalizeNewlines: true, sessionId: `plugin:${plugin.id}` },
      { kill: () => child.kill(), resize: () => undefined, write: () => undefined }
    )
    if (terminal !== undefined) {
      terminal.output(`$ ${displayPluginCommand(runCommand)}\r\n`)
      child.onOutput?.((data) => terminal.output(data))
    }
    child.onExit((message) => {
      exitMessage = message
      terminal?.exit()
      const state = runtime(plugin.id)
      if (state.process === child && state.state === "running") {
        log(`Plugin ${plugin.id} ${message.split("\n")[0]}`)
        setState(plugin.id, state, registerFailure(state))
        config.onUnexpectedExit?.(plugin.id)
      }
    })
    current.process = child
    const deadline = now() + READY_TIMEOUT_MS
    while (now() < deadline) {
      if (exitMessage !== undefined) {
        throw new PluginsError("invalid", `Plugin ${plugin.id} ${exitMessage}`)
      }
      const ready =
        plugin.manifest.healthPath === undefined
          ? await tcpProbe(port)
          : await httpProbe(port, plugin.manifest.healthPath)
      checkOwner()
      /* v8 ignore next */
      if (ready) {
        current.port = port
        const lease = { port }
        current.lease = lease
        current.runningSince = now()
        setState(plugin.id, current, "running")
        log(`Plugin ${plugin.id} listening on 127.0.0.1:${port}`)
        return lease
      }
      await sleep(150)
      checkOwner()
    }
    child.kill()
    throw new PluginsError(
      "invalid",
      `Plugin ${plugin.id} did not start listening on $PORT within ${READY_TIMEOUT_MS}ms`
    )
  }

  const stop = (pluginId: string): void => {
    const current = runtimes.get(pluginId)
    if (current === undefined) {
      return
    }
    current.failures = 0
    current.notBefore = 0
    current.generation += 1
    delete current.startPromise
    if (current.state === "stopped") {
      return
    }
    setState(pluginId, current, "stopping")
    current.process?.kill()
    clearProcess(current)
    setState(pluginId, current, "stopped")
  }

  const acquire = async (plugin: InstalledPlugin): Promise<PluginLease> => {
    const current = runtime(plugin.id)
    if (current.state === "running" && current.lease !== undefined) {
      return current.lease
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
    const generation = ++current.generation
    const startPromise = start(plugin, current, generation).catch((cause: unknown) => {
      if (current.generation === generation) {
        current.process?.kill()
        setState(plugin.id, current, registerFailure(current))
      }
      throw cause
    })
    current.startPromise = startPromise
    try {
      return await startPromise
    } finally {
      if (current.startPromise === startPromise) delete current.startPromise
    }
  }

  return {
    acquire,
    ensureRunning: async (plugin) => (await acquire(plugin)).port,
    closeAll: () => {
      for (const pluginId of runtimes.keys()) stop(pluginId)
    },
    markUnreachable: (pluginId, lease) => {
      const current = runtimes.get(pluginId)
      if (current === undefined || current.state !== "running" || current.lease !== lease) {
        return
      }
      log(`Plugin ${pluginId} stopped answering on 127.0.0.1:${current.port}; treating as crashed`)
      const child = current.process
      const nextState = registerFailure(current)
      /* v8 ignore next */
      child?.kill()
      setState(pluginId, current, nextState)
      config.onUnexpectedExit?.(pluginId)
    },
    noteSuccess: (pluginId, lease) => {
      const current = runtimes.get(pluginId)
      if (current === undefined || current.lease !== lease) {
        return
      }
      current.failures = 0
      current.notBefore = 0
      current.runningSince = now()
    },
    restart: (pluginId) => stop(pluginId),
    state: (pluginId) => runtimes.get(pluginId)?.state ?? "stopped",
    stop
  }
}

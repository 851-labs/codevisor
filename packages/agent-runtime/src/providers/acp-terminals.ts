import { randomUUID } from "node:crypto"
import { spawn } from "node:child_process"
import {
  backgroundTerminalKey,
  DEFAULT_PROMOTION_DELAY_MS,
  type BackgroundTerminalIntegration,
  type ExternalTerminalStream
} from "../background-terminals.js"
import type { RuntimeEmit } from "../types.js"

/// Client-side implementation of the ACP `terminal/*` methods, backed by the
/// server's background-terminal registry.
///
/// Advertising the `terminal` capability makes ACP agents run shell commands
/// in processes WE own: the host spawns them, buffers output for
/// `terminal/output` polls, and mirrors every byte into a registered external
/// terminal. Short-lived commands stay invisible (removed on release); a
/// command still alive after the promotion delay is a background process —
/// dev server, watcher — and gets surfaced as a `BackgroundTask` with a
/// `terminalKey`, which clients render as a live terminal tab.

export interface AcpTerminalChild {
  readonly onOutput: (callback: (data: string) => void) => void
  readonly onExit: (
    callback: (exitCode: number | undefined, signal: string | undefined) => void
  ) => void
  readonly write: (data: string) => void
  readonly kill: () => void
}

export type AcpTerminalSpawner = (
  command: string,
  args: ReadonlyArray<string>,
  options: { readonly cwd?: string; readonly env: NodeJS.ProcessEnv }
) => AcpTerminalChild

export interface AcpTerminalCreateParams {
  readonly sessionId: string
  readonly command: string
  readonly args?: ReadonlyArray<string>
  readonly env?: ReadonlyArray<{ readonly name: string; readonly value: string }>
  readonly cwd?: string | null
  readonly outputByteLimit?: number | null
}

export interface AcpTerminalExitStatus {
  readonly exitCode?: number
  readonly signal?: string
}

export interface AcpTerminalOutputResponse {
  readonly output: string
  readonly truncated: boolean
  readonly exitStatus?: AcpTerminalExitStatus
}

export interface AcpTerminalHost {
  readonly create: (params: AcpTerminalCreateParams) => { readonly terminalId: string }
  readonly output: (params: {
    readonly sessionId: string
    readonly terminalId: string
  }) => AcpTerminalOutputResponse
  readonly waitForExit: (params: {
    readonly sessionId: string
    readonly terminalId: string
  }) => Promise<AcpTerminalExitStatus>
  readonly kill: (params: { readonly sessionId: string; readonly terminalId: string }) => void
  readonly release: (params: { readonly sessionId: string; readonly terminalId: string }) => void
  /// Connection teardown: kills every process that is still running and
  /// removes terminals that were never surfaced to a client. Promoted
  /// terminals keep their scrollback (the tab outlives the agent process).
  readonly closeAll: () => void
}

export interface AcpTerminalHostConfig {
  readonly integration: BackgroundTerminalIntegration
  readonly emit: RuntimeEmit
  readonly env: NodeJS.ProcessEnv
  /// Standard ACP treats `command` as an executable with a separate argv.
  /// Grok currently sends a complete shell invocation in `command` with an
  /// empty argv, so its connection opts into executing that string via a
  /// shell instead.
  readonly commandMode?: "argv" | "shell"
  readonly spawner?: AcpTerminalSpawner
}

interface AcpTerminalEntry {
  readonly terminalId: string
  readonly sessionId: string
  readonly description: string
  readonly child: AcpTerminalChild
  readonly stream: ExternalTerminalStream
  readonly terminalKey: string
  buffer: string
  truncated: boolean
  readonly byteLimit: number | undefined
  exitStatus: AcpTerminalExitStatus | undefined
  readonly exitWaiters: Array<(status: AcpTerminalExitStatus) => void>
  promoted: boolean
  released: boolean
  promotionTimer: NodeJS.Timeout | undefined
}

export const makeAcpTerminalHost = (config: AcpTerminalHostConfig): AcpTerminalHost => {
  const spawner = config.spawner ?? nodeChildProcessSpawner
  const registry = config.integration.registry
  const promotionDelayMs = config.integration.promotionDelayMs ?? DEFAULT_PROMOTION_DELAY_MS
  const terminals = new Map<string, AcpTerminalEntry>()

  const emitTasks = (sessionId: string): void => {
    const backgroundTasks = [...terminals.values()]
      .filter(
        (entry) => entry.sessionId === sessionId && entry.promoted && entry.exitStatus === undefined
      )
      .map((entry) => ({
        description: entry.description,
        id: entry.terminalId,
        status: "running",
        taskType: "shell",
        terminalKey: entry.terminalKey
      }))
    void config.emit({
      kind: "session.updated",
      payload: { backgroundTasks },
      subjectId: sessionId
    })
  }

  const getEntry = (terminalId: string): AcpTerminalEntry => {
    const entry = terminals.get(terminalId)
    if (entry === undefined) {
      throw new Error(`Unknown terminal: ${terminalId}`)
    }
    return entry
  }

  const settleExit = (entry: AcpTerminalEntry, status: AcpTerminalExitStatus): void => {
    if (entry.exitStatus !== undefined) return
    entry.exitStatus = status
    entry.stream.exit(status.exitCode)
    clearPromotionTimer(entry)
    for (const waiter of entry.exitWaiters.splice(0)) {
      waiter(status)
    }
    if (entry.promoted) {
      // The task is done, but the entry stays until release so the agent can
      // still poll output/waitForExit; the terminal (and its tab) stays
      // attachable for scrollback until the user closes it.
      emitTasks(entry.sessionId)
    }
    if (entry.released) {
      removeEntry(entry)
    }
  }

  const removeEntry = (entry: AcpTerminalEntry): void => {
    clearPromotionTimer(entry)
    if (!entry.promoted) {
      entry.stream.remove()
    }
    terminals.delete(entry.terminalId)
  }

  return {
    create: (params) => {
      const terminalId = randomUUID()
      const terminalKey = backgroundTerminalKey(params.sessionId, terminalId)
      const commandLine = [params.command, ...(params.args ?? [])].join(" ")
      const env: NodeJS.ProcessEnv = { ...config.env }
      for (const variable of params.env ?? []) {
        env[variable.name] = variable.value
      }
      const spawnRequest = terminalSpawnRequest(
        params.command,
        params.args ?? [],
        config.commandMode ?? "argv"
      )
      const child = spawner(spawnRequest.command, spawnRequest.args, {
        env,
        ...(typeof params.cwd === "string" ? { cwd: params.cwd } : {})
      })
      const stream = registry.register(terminalKey, {
        kill: () => child.kill(),
        write: (data) => child.write(data)
      })
      const entry: AcpTerminalEntry = {
        buffer: "",
        byteLimit: params.outputByteLimit ?? undefined,
        child,
        description: firstLine(commandLine),
        exitStatus: undefined,
        exitWaiters: [],
        promoted: false,
        promotionTimer: undefined,
        released: false,
        sessionId: params.sessionId,
        stream,
        terminalId,
        terminalKey,
        truncated: false
      }
      terminals.set(terminalId, entry)
      child.onOutput((data) => {
        entry.buffer += data
        if (entry.byteLimit !== undefined && byteLength(entry.buffer) > entry.byteLimit) {
          entry.buffer = truncateToByteLimit(entry.buffer, entry.byteLimit)
          entry.truncated = true
        }
        stream.output(data)
      })
      child.onExit((exitCode, signal) => {
        settleExit(entry, {
          ...(exitCode === undefined ? {} : { exitCode }),
          ...(signal === undefined ? {} : { signal })
        })
      })
      entry.promotionTimer = setTimeout(() => {
        entry.promotionTimer = undefined
        if (entry.exitStatus !== undefined) return
        entry.promoted = true
        emitTasks(entry.sessionId)
      }, promotionDelayMs)
      return { terminalId }
    },
    output: (params) => {
      const entry = getEntry(params.terminalId)
      return {
        output: entry.buffer,
        truncated: entry.truncated,
        ...(entry.exitStatus === undefined ? {} : { exitStatus: entry.exitStatus })
      }
    },
    waitForExit: (params) => {
      const entry = getEntry(params.terminalId)
      if (entry.exitStatus !== undefined) {
        return Promise.resolve(entry.exitStatus)
      }
      return new Promise((resolve) => {
        entry.exitWaiters.push(resolve)
      })
    },
    kill: (params) => {
      const entry = getEntry(params.terminalId)
      if (entry.exitStatus === undefined) {
        entry.child.kill()
      }
    },
    release: (params) => {
      const entry = getEntry(params.terminalId)
      entry.released = true
      if (entry.exitStatus === undefined) {
        // Per ACP spec, releasing a running terminal kills its command. The
        // exit callback finishes the cleanup.
        entry.child.kill()
        return
      }
      removeEntry(entry)
    },
    closeAll: () => {
      for (const entry of [...terminals.values()]) {
        if (entry.exitStatus === undefined) {
          entry.child.kill()
        }
        removeEntry(entry)
      }
    }
  }
}

const clearPromotionTimer = (entry: AcpTerminalEntry): void => {
  if (entry.promotionTimer !== undefined) {
    clearTimeout(entry.promotionTimer)
    entry.promotionTimer = undefined
  }
}

const firstLine = (value: string): string => value.split("\n", 1)[0] ?? value

const byteLength = (value: string): number => Buffer.byteLength(value, "utf8")

export const terminalSpawnRequest = (
  command: string,
  args: ReadonlyArray<string>,
  mode: "argv" | "shell"
): { readonly command: string; readonly args: ReadonlyArray<string> } =>
  mode === "shell"
    ? process.platform === "win32"
      ? {
          command: process.env.ComSpec ?? "cmd.exe",
          args: ["/d", "/s", "/c", command]
        }
      : { command: "/bin/sh", args: ["-lc", command] }
    : { command, args }

/// Truncates from the BEGINNING (per ACP spec) at a character boundary.
const truncateToByteLimit = (value: string, limit: number): string => {
  const bytes = Buffer.from(value, "utf8")
  if (bytes.length <= limit) return value
  const sliced = bytes.subarray(bytes.length - limit)
  // Dropping partial UTF-8 continuation bytes at the cut keeps the string valid.
  let start = 0
  while (start < sliced.length && (sliced[start]! & 0b1100_0000) === 0b1000_0000) {
    start += 1
  }
  return sliced.subarray(start).toString("utf8")
}

/* v8 ignore start -- real child_process spawning is exercised by integration smoke tests. */
export const nodeChildProcessSpawner: AcpTerminalSpawner = (command, args, options) => {
  const child = spawn(command, [...args], {
    cwd: options.cwd,
    env: options.env,
    stdio: ["pipe", "pipe", "pipe"]
  })
  return {
    onOutput: (callback) => {
      child.stdout.setEncoding("utf8")
      child.stderr.setEncoding("utf8")
      child.stdout.on("data", callback)
      child.stderr.on("data", callback)
    },
    onExit: (callback) => {
      child.once("exit", (code, signal) => callback(code ?? undefined, signal ?? undefined))
      child.once("error", () => callback(undefined, undefined))
    },
    write: (data) => {
      child.stdin.write(data)
    },
    kill: () => {
      child.kill()
    }
  }
}
/* v8 ignore stop */

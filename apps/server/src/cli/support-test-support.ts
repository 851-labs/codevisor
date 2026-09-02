import type { CliDeps, ExecResult } from "./support.js"

/// A scripted fake of the CLI's process/exec/http world for the support tests.

export interface FakeWorld {
  readonly deps: CliDeps
  readonly logs: string[]
  readonly errors: string[]
  readonly execCalls: Array<string>
  readonly interactiveCalls: Array<string>
  readonly spawned: Array<{ args: ReadonlyArray<string>; logPath: string }>
  readonly files: Map<string, string>
  readonly signals: Array<{ pid: number; signal: string }>
}

export interface FakeOptions {
  /// Keyed by "command arg arg…" → result (or a queue of results).
  readonly exec?: Record<string, ExecResult>
  /// Keyed by "METHOD url" → response bodies returned in order (last repeats).
  readonly http?: Record<string, ReadonlyArray<{ status: number; body?: unknown } | undefined>>
  readonly files?: Record<string, string>
  readonly alivePids?: ReadonlyArray<number>
  readonly killStopsPid?: boolean
  readonly isRoot?: boolean
  readonly env?: Record<string, string | undefined>
  readonly installedVersion?: string
  readonly interactiveExit?: number
  readonly spawnPid?: number
}

export const failure: ExecResult = { code: 1, stdout: "", stderr: "" }

export const makeWorld = (options: FakeOptions = {}): FakeWorld => {
  const logs: string[] = []
  const errors: string[] = []
  const execCalls: string[] = []
  const interactiveCalls: string[] = []
  const spawned: Array<{ args: ReadonlyArray<string>; logPath: string }> = []
  const files = new Map<string, string>(Object.entries(options.files ?? {}))
  const signals: Array<{ pid: number; signal: string }> = []
  const alive = new Set(options.alivePids ?? [])
  const httpCounts = new Map<string, number>()

  const deps: CliDeps = {
    exec: (command, args) => {
      const key = [command, ...args].join(" ")
      execCalls.push(key)
      return Promise.resolve(options.exec?.[key] ?? failure)
    },
    execInteractive: (command, args) => {
      interactiveCalls.push([command, ...args].join(" "))
      return Promise.resolve(options.interactiveExit ?? 0)
    },
    spawnDetachedServer: (args, logPath) => {
      spawned.push({ args, logPath })
      return Promise.resolve(options.spawnPid ?? 4242)
    },
    fetchJson: (url, init) => {
      const key = `${init?.method ?? "GET"} ${url}`
      const responses = options.http?.[key] ?? [undefined]
      const index = httpCounts.get(key) ?? 0
      httpCounts.set(key, index + 1)
      const response = responses[Math.min(index, responses.length - 1)]
      return Promise.resolve(
        response === undefined ? undefined : { status: response.status, body: response.body }
      )
    },
    readTextFile: (path) => files.get(path),
    writeTextFile: (path, contents) => void files.set(path, contents),
    removeFile: (path) => void files.delete(path),
    processAlive: (pid) => alive.has(pid),
    signal: (pid, signal) => {
      signals.push({ pid, signal })
      if (options.killStopsPid !== false) alive.delete(pid)
      return true
    },
    sleep: () => Promise.resolve(),
    env: options.env ?? {},
    isRoot: options.isRoot ?? false,
    installedVersion: () => options.installedVersion,
    dataDir: "/home/user/.codevisor/data",
    logsDir: "/home/user/.codevisor/logs",
    log: (line) => void logs.push(line),
    error: (line) => void errors.push(line)
  }
  return { deps, logs, errors, execCalls, interactiveCalls, spawned, files, signals }
}

export const unit = (port: number): ExecResult => ({
  code: 0,
  stdout: `[Service]\nExecStart=/opt/codevisor/bin/codevisor-server serve --host 0.0.0.0 --port ${port} --auth token\n`,
  stderr: ""
})

export const systemCat = "systemctl cat codevisor-server.service"
export const userCat = "systemctl --user cat codevisor-server.service"
export const health = (port: number): string => `GET http://127.0.0.1:${port}/v1/health`
export const ok = { status: 200, body: { ok: true } }

import { spawn, type ChildProcess } from "node:child_process"

import type { PluginProcessHandle, PluginSpawnOptions } from "./plugin-supervisor.js"

const terminatePluginProcess = (child: ChildProcess): void => {
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
    kill: () => terminatePluginProcess(child),
    onExit: (listener) => {
      exitListeners.push(listener)
    },
    onOutput: (listener) => {
      outputListeners.push(listener)
    },
    pid: child.pid
  }
}

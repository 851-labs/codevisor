import { execFile, spawn } from "node:child_process"

import { childStdioEndpoint, makeNdjsonTransport } from "@codevisor/agent-runtime"
import type { NdjsonTransport } from "@codevisor/agent-runtime"
import {
  processIdentity,
  stopProcessTree,
  stopTreeOnExit,
  trackProcessTree
} from "@codevisor/processes"

import { record } from "./protocol.js"

export interface AgyProcess {
  readonly send: (message: Record<string, unknown>) => void
  readonly onEvent: (handler: (event: Record<string, unknown>) => void) => void
  readonly onExit: (handler: (error: Error) => void) => void
  readonly interrupt: () => void
  readonly close: () => void
}

export interface AgySpawnRequest {
  readonly command: string
  readonly args: ReadonlyArray<string>
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
}

export type AgyConnector = (request: AgySpawnRequest) => Promise<AgyProcess>

export interface AgyRunResult {
  readonly code: number
  readonly stdout: string
  readonly stderr: string
}

export type AgyRunner = (
  request: AgySpawnRequest & { readonly timeoutMs: number }
) => Promise<AgyRunResult>

export const wireAgyProcess = (
  transport: NdjsonTransport,
  interrupt: () => void,
  stop: () => void = () => transport.close()
): AgyProcess => {
  let eventHandler: ((event: Record<string, unknown>) => void) | undefined
  transport.onLine((line) => {
    let event: unknown
    try {
      event = JSON.parse(line)
    } catch {
      return
    }
    try {
      eventHandler?.(record(event))
    } catch (error) {
      console.error("Error handling agy event", error)
    }
  })
  return {
    send: (message) => transport.send(message),
    onEvent: (handler) => {
      eventHandler = handler
    },
    onExit: (handler) => transport.onFailure(handler),
    interrupt,
    close: stop
  }
}

/* v8 ignore start */
export const spawnAgyProcess: AgyConnector = async (request) => {
  const child = spawn(request.command, [...request.args], {
    cwd: request.cwd,
    env: request.env,
    detached: process.platform !== "win32",
    stdio: ["pipe", "pipe", "pipe"]
  })
  await new Promise<void>((resolve, reject) => {
    child.once("spawn", () => resolve())
    child.once("error", reject)
  })
  const transport = makeNdjsonTransport(childStdioEndpoint(child), { exitMessage: "agy exited" })
  const pid = child.pid!
  const identity = await processIdentity(pid)
  const tree = await trackProcessTree(pid)
  stopTreeOnExit(child, tree)
  const interrupt = () => {
    try {
      process.kill(process.platform === "win32" ? pid : -pid, "SIGINT")
    } catch {
      child.kill("SIGINT")
    }
  }
  return wireAgyProcess(transport, interrupt, () => {
    transport.close()
    void (identity === undefined ? Promise.resolve() : stopProcessTree(pid, { identity })).catch(
      () => child.kill()
    )
  })
}

export const runAgy: AgyRunner = (request) =>
  new Promise((resolve, reject) => {
    execFile(
      request.command,
      [...request.args],
      {
        cwd: request.cwd,
        env: request.env,
        timeout: request.timeoutMs,
        maxBuffer: 4 * 1024 * 1024
      },
      (error, stdout, stderr) => {
        if (error !== null && typeof error.code !== "number") {
          reject(error.killed ? new Error("Antigravity didn't respond in time.") : error)
          return
        }
        resolve({ code: error === null ? 0 : (error.code as number), stdout, stderr })
      }
    )
  })
/* v8 ignore stop */

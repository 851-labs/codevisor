import { spawn } from "node:child_process"

import { childStdioEndpoint, makeNdjsonTransport } from "@codevisor/agent-runtime"
import type { NdjsonTransport } from "@codevisor/agent-runtime"
import { isRecord } from "@codevisor/api"
import {
  processIdentity,
  stopProcessTree,
  stopTreeOnExit,
  trackProcessTree
} from "@codevisor/processes"

export interface PiClient {
  command: (type: string, fields?: Record<string, unknown>) => Promise<unknown>
  onEvent: (handler: (event: Record<string, unknown>) => void) => void
  respond: (response: Record<string, unknown>) => void
  onClose: (handler: (error: Error) => void) => void
  close: () => void
}

export interface PiSpawnRequest {
  readonly command: string
  readonly args: ReadonlyArray<string>
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
}

export type PiConnector = (request: PiSpawnRequest) => Promise<PiClient>

/* v8 ignore start */
export const spawnPiClient: PiConnector = async (request) => {
  const child = spawn(request.command, ["--mode", "rpc", ...request.args], {
    cwd: request.cwd,
    env: request.env,
    detached: process.platform !== "win32",
    stdio: ["pipe", "pipe", "pipe"]
  })
  await new Promise<void>((resolve, reject) => {
    child.once("spawn", () => resolve())
    child.once("error", reject)
  })
  const client = wirePiClient(
    makeNdjsonTransport(childStdioEndpoint(child), { exitMessage: "pi exited" })
  )
  const pid = child.pid!
  const identity = await processIdentity(pid)
  const tree = await trackProcessTree(pid)
  stopTreeOnExit(child, tree)
  return {
    ...client,
    close: () => {
      client.close()
      let stopping: Promise<void>
      if (identity === undefined) stopping = Promise.resolve()
      else stopping = stopProcessTree(pid, { identity })
      void stopping.catch(() => child.kill())
    }
  }
}
/* v8 ignore stop */

export class PiExitedError extends Error {}

interface Pending {
  readonly resolve: (value: unknown) => void
  readonly reject: (error: Error) => void
}

export const wirePiClient = (transport: NdjsonTransport): PiClient => {
  let next = 0
  const pending = new Map<string, Pending>()
  let eventHandler: ((event: Record<string, unknown>) => void) | undefined
  const closeHandlers: Array<(error: Error) => void> = []
  let stopped: Error | undefined

  const settle = (error: Error, notify: boolean): void => {
    if (stopped !== undefined) return
    stopped = error
    for (const entry of pending.values()) entry.reject(error)
    pending.clear()
    if (notify) for (const handler of closeHandlers) handler(error)
  }
  transport.onFailure((error) => settle(new PiExitedError(error.message), true))

  transport.onLine((line) => {
    let record: unknown
    try {
      record = JSON.parse(line)
    } catch {
      return
    }
    if (!isRecord(record)) return
    if (record.type === "response") {
      const id = record.id
      if (typeof id !== "string") return
      const entry = pending.get(id)
      if (entry === undefined) return
      pending.delete(id)
      if (record.success === true) entry.resolve(record.data)
      else entry.reject(new Error(typeof record.error === "string" ? record.error : "Pi failed."))
      return
    }
    try {
      eventHandler?.(record)
    } catch (error) {
      console.error(`Error handling pi event ${String(record.type)}`, error)
    }
  })

  return {
    command: (type: string, fields: Record<string, unknown> = {}) => {
      next += 1
      const id = `codevisor-${next}`
      return new Promise<unknown>((resolve, reject) => {
        if (stopped !== undefined) {
          reject(stopped)
          return
        }
        pending.set(id, { reject, resolve })
        transport.send({ ...fields, id, type })
      })
    },
    onEvent: (handler) => {
      eventHandler = handler
    },
    respond: (response) => transport.send({ ...response, type: "extension_ui_response" }),
    onClose: (handler) => {
      closeHandlers.push(handler)
    },
    close: () => {
      settle(new Error("Pi was closed."), false)
      transport.close()
    }
  }
}

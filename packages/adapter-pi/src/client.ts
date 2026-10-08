import { spawn } from "node:child_process"

import { childStdioEndpoint, makeNdjsonTransport } from "@codevisor/agent-runtime"
import type { NdjsonTransport } from "@codevisor/agent-runtime"
import {
  processIdentity,
  stopProcessTree,
  stopTreeOnExit,
  trackProcessTree
} from "@codevisor/processes"

/// A client for Pi's RPC mode (`pi --mode rpc`): JSON records over stdio.
/// Commands carry an `id` their `response` repeats; everything else Pi
/// writes is a session event or an extension UI request.
export interface PiClient {
  /// Sends a command and resolves with its response's `data`, or rejects
  /// with Pi's error.
  command: <T = unknown>(type: string, fields?: Record<string, unknown>) => Promise<T>
  /// Session events and extension UI requests, in the order Pi wrote them.
  onEvent: (handler: (event: Record<string, unknown>) => void) => void
  /// Answers an extension UI request.
  respond: (response: Record<string, unknown>) => void
  /// Pi exited or its pipe failed. Not called for `close()`.
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

/* v8 ignore start -- spawning runs against a live pi binary; tests drive wirePiClient over fake endpoints. */
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
  // Pi's bash tool starts commands of its own; they go with the chat.
  const tree = await trackProcessTree(pid)
  stopTreeOnExit(child, tree)
  return {
    ...client,
    close: () => {
      client.close()
      void (identity === undefined ? Promise.resolve() : stopProcessTree(pid, { identity })).catch(
        () => child.kill()
      )
    }
  }
}
/* v8 ignore stop */

/// Pi itself stopped (it exited, or its pipe failed), as opposed to Pi
/// answering a command with an error. Carries Pi's own account of why.
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
  /// Why the client stopped, once it has: later commands fail with it, so a
  /// Pi that died before its first command still says why.
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
    let record: Record<string, unknown>
    try {
      record = JSON.parse(line) as Record<string, unknown>
    } catch {
      return
    }
    if (record.type === "response") {
      const entry = typeof record.id === "string" ? pending.get(record.id) : undefined
      if (entry === undefined) return
      pending.delete(record.id as string)
      if (record.success === true) entry.resolve(record.data)
      else entry.reject(new Error(typeof record.error === "string" ? record.error : "Pi failed."))
      return
    }
    // Handlers run inside the stream listener: one bad event must not take
    // the server (and every other chat) down with it.
    try {
      eventHandler?.(record)
    } catch (error) {
      console.error(`Error handling pi event ${String(record.type)}`, error)
    }
  })

  return {
    command: <T>(type: string, fields: Record<string, unknown> = {}) => {
      next += 1
      const id = `codevisor-${next}`
      return new Promise<T>((resolve, reject) => {
        if (stopped !== undefined) {
          reject(stopped)
          return
        }
        pending.set(id, { reject, resolve: resolve as (value: unknown) => void })
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

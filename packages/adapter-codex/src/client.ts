import { spawn } from "node:child_process"

import { childStdioEndpoint, makeNdjsonTransport } from "@codevisor/agent-runtime"
import type { NdjsonTransport } from "@codevisor/agent-runtime"
import {
  processIdentity,
  stopProcessTree,
  stopTreeOnExit,
  trackProcessTree
} from "@codevisor/processes"

import { isRecord } from "./internal.js"

export interface CodexClient {
  request: <T>(method: string, params?: unknown) => Promise<T>
  notify: (method: string, params?: unknown) => void
  onNotification: (handler: (method: string, params: unknown) => void) => void
  onRequest: (
    handler: (method: string, params: unknown, signal: AbortSignal) => Promise<unknown>
  ) => void
  onClose: (handler: (error: Error) => void) => void
  close: () => void
  closeAndWait?: () => Promise<void>
  authRejected?: () => boolean
}

export interface CodexSpawnRequest {
  readonly command: string
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
  readonly disabledFeatures?: ReadonlyArray<string>
}

export type CodexConnector = (request: CodexSpawnRequest) => Promise<CodexClient>

interface Pending {
  readonly resolve: (value: unknown) => void
  readonly reject: (error: Error) => void
}

/* v8 ignore start */
export const spawnCodexClient: CodexConnector = async (request) => {
  const child = spawn(
    request.command,
    [
      "app-server",
      "-c",
      "features.apply_patch_streaming_events=true",
      "-c",
      "features.default_mode_request_user_input=true",
      ...(request.disabledFeatures ?? []).flatMap((feature) => ["-c", `features.${feature}=false`])
    ],
    {
      cwd: request.cwd,
      env: request.env,
      detached: process.platform !== "win32",
      stdio: ["pipe", "pipe", "pipe"]
    }
  )
  await new Promise<void>((resolve, reject) => {
    child.once("spawn", () => resolve())
    child.once("error", reject)
  })
  const transport = makeNdjsonTransport(childStdioEndpoint(child), {
    exitMessage: "codex app-server exited",
    isolateCodexHistory: true
  })
  const client = wireCodexClient(transport)
  const pid = child.pid!
  const identity = await processIdentity(pid)
  const tree = await trackProcessTree(pid)
  stopTreeOnExit(child, tree)
  let closing: Promise<void> | undefined
  const closeAndWait = (): Promise<void> => {
    closing ??= (async () => {
      try {
        await tree.stop({ includeRoot: false })
      } finally {
        client.close()
        if (identity !== undefined) await stopProcessTree(pid, { identity })
      }
    })()
    return closing
  }
  return {
    ...client,
    closeAndWait,
    close: () => {
      void closeAndWait().catch(() => child.kill())
    }
  }
}
/* v8 ignore stop */

export const wireCodexClient = (transport: NdjsonTransport): CodexClient => {
  let nextId = 1
  const pending = new Map<number, Pending>()
  const inbound = new Map<number, AbortController>()
  let notificationHandler: ((method: string, params: unknown) => void) | undefined
  let requestHandler:
    | ((method: string, params: unknown, signal: AbortSignal) => Promise<unknown>)
    | undefined
  const closeHandlers: Array<(error: Error) => void> = []
  let closed = false

  const settle = (error: Error, notifyClose: boolean): void => {
    if (closed) return
    closed = true
    for (const entry of pending.values()) {
      entry.reject(error)
    }
    pending.clear()
    for (const controller of inbound.values()) {
      controller.abort(error)
    }
    inbound.clear()
    if (notifyClose) {
      for (const handler of closeHandlers) {
        handler(error)
      }
    }
  }

  transport.onFailure((error) => settle(error, true))

  const handleMessage = (message: Record<string, unknown>): void => {
    const id = message.id
    if (typeof id === "number" && ("result" in message || "error" in message)) {
      const entry = pending.get(id)
      if (entry !== undefined) {
        pending.delete(id)
        if ("error" in message && message.error !== undefined && message.error !== null) {
          const error = message.error as { message?: string; code?: number }
          entry.reject(new Error(error.message ?? `codex error ${error.code ?? "unknown"}`))
        } else {
          entry.resolve(message.result)
        }
      }
      return
    }
    const method = message.method
    if (typeof method !== "string") return
    if (typeof id === "number") {
      const handler = requestHandler
      if (handler === undefined) {
        transport.send({ error: { code: -32601, message: `No handler for ${method}` }, id })
        return
      }
      const controller = new AbortController()
      inbound.set(id, controller)
      const respond = (payload: Record<string, unknown>): void => {
        if (inbound.get(id) !== controller) return
        inbound.delete(id)
        transport.send(payload)
      }
      let reply: Promise<unknown>
      try {
        reply = handler(method, message.params, controller.signal)
      } catch (error) {
        reply = Promise.reject(error)
      }
      reply
        .then((result) => respond({ id, result }))
        .catch((error: unknown) =>
          respond({
            error: {
              code: -32000,
              message: error instanceof Error ? error.message : String(error)
            },
            id
          })
        )
      return
    }
    try {
      notificationHandler?.(method, message.params)
    } catch (error) {
      console.error(`Error handling codex notification ${method}`, error)
    }
  }
  if (transport.onMessage !== undefined) transport.onMessage(handleMessage)
  else
    transport.onLine((line) => {
      let message: unknown
      try {
        message = JSON.parse(line)
      } catch {
        return
      }
      if (isRecord(message)) handleMessage(message)
    })

  return {
    close: () => {
      settle(new Error("codex client closed"), false)
      transport.close()
    },
    notify: (method, params) => {
      transport.send(params === undefined ? { method } : { method, params })
    },
    onClose: (handler) => {
      closeHandlers.push(handler)
    },
    onNotification: (handler) => {
      notificationHandler = handler
    },
    onRequest: (handler) => {
      requestHandler = handler
    },
    request: <T>(method: string, params?: unknown): Promise<T> => {
      const id = nextId
      nextId += 1
      return new Promise<T>((resolve, reject) => {
        if (closed) {
          reject(new Error("codex app-server connection is closed"))
          return
        }
        // oxlint-disable-next-line typescript/no-unsafe-type-assertion
        pending.set(id, { reject, resolve: resolve as (value: unknown) => void })
        transport.send(params === undefined ? { id, method } : { id, method, params })
      })
    }
  }
}

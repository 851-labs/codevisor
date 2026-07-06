import { spawn } from "node:child_process"
import type { ChildProcessWithoutNullStreams } from "node:child_process"

/// Minimal JSON-RPC 2.0 client over newline-delimited JSON, the codex
/// app-server's stdio transport (the `jsonrpc` header is omitted on the wire).
export interface CodexClient {
  request: <T>(method: string, params?: unknown) => Promise<T>
  notify: (method: string, params?: unknown) => void
  onNotification: (handler: (method: string, params: unknown) => void) => void
  /// Server→client requests (approvals). The handler's resolved value is sent
  /// back as the JSON-RPC result.
  onRequest: (handler: (method: string, params: unknown) => Promise<unknown>) => void
  onClose: (handler: (error: Error) => void) => void
  close: () => void
  /// OS pid of the spawned codex app-server process, when this client wraps a
  /// real child process. The protocol offers no way to kill an agent-run
  /// command, so best-effort kill walks this process's descendants instead.
  readonly pid?: number
}

export interface CodexSpawnRequest {
  readonly command: string
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
}

export type CodexConnector = (request: CodexSpawnRequest) => Promise<CodexClient>

interface Pending {
  readonly resolve: (value: unknown) => void
  readonly reject: (error: Error) => void
}

/* v8 ignore start -- the stdio transport is exercised against a live codex binary; tests inject a fake client. */
export const spawnCodexClient: CodexConnector = async (request) => {
  // apply_patch_streaming_events unlocks item/fileChange/patchUpdated — the
  // realtime patch stream while the model generates an edit.
  // default_mode_request_user_input lets the model ask the user questions
  // (item/tool/requestUserInput) in the default collaboration mode.
  // Both are off by default upstream (under development); unknown keys only
  // produce a warning on older builds.
  const child = spawn(
    request.command,
    [
      "app-server",
      "-c",
      "features.apply_patch_streaming_events=true",
      "-c",
      "features.default_mode_request_user_input=true"
    ],
    {
      cwd: request.cwd,
      env: request.env,
      stdio: ["pipe", "pipe", "pipe"]
    }
  )
  await new Promise<void>((resolve, reject) => {
    child.once("spawn", () => resolve())
    child.once("error", reject)
  })
  const client = wireCodexClient(child)
  return child.pid === undefined ? client : { ...client, pid: child.pid }
}

const wireCodexClient = (child: ChildProcessWithoutNullStreams): CodexClient => {
  let nextId = 1
  const pending = new Map<number, Pending>()
  let notificationHandler: ((method: string, params: unknown) => void) | undefined
  let requestHandler: ((method: string, params: unknown) => Promise<unknown>) | undefined
  const closeHandlers: Array<(error: Error) => void> = []
  let stderrTail = ""
  let closed = false

  child.stderr.setEncoding("utf8")
  child.stderr.on("data", (chunk: string) => {
    stderrTail = `${stderrTail}${chunk}`.slice(-8192)
  })

  const failAll = (error: Error): void => {
    if (closed) return
    closed = true
    for (const entry of pending.values()) {
      entry.reject(error)
    }
    pending.clear()
    for (const handler of closeHandlers) {
      handler(error)
    }
  }

  child.once("exit", () => {
    failAll(new Error(stderrTail.length > 0 ? stderrTail : "codex app-server exited"))
  })
  child.once("error", (error) => failAll(error))

  const send = (payload: Record<string, unknown>): void => {
    child.stdin.write(`${JSON.stringify(payload)}\n`)
  }

  const handleLine = (line: string): void => {
    if (line.trim().length === 0) return
    let message: Record<string, unknown>
    try {
      message = JSON.parse(line) as Record<string, unknown>
    } catch {
      return
    }
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
      // Server→client request (approvals).
      const handler = requestHandler
      if (handler === undefined) {
        send({ error: { code: -32601, message: `No handler for ${method}` }, id })
        return
      }
      handler(method, message.params)
        .then((result) => send({ id, result }))
        .catch((error: unknown) =>
          send({
            error: {
              code: -32000,
              message: error instanceof Error ? error.message : String(error)
            },
            id
          })
        )
      return
    }
    notificationHandler?.(method, message.params)
  }

  let buffer = ""
  child.stdout.setEncoding("utf8")
  child.stdout.on("data", (chunk: string) => {
    buffer += chunk
    while (true) {
      const newline = buffer.indexOf("\n")
      if (newline === -1) break
      const line = buffer.slice(0, newline)
      buffer = buffer.slice(newline + 1)
      handleLine(line)
    }
  })

  return {
    close: () => {
      child.stdin.end()
      child.kill()
    },
    notify: (method, params) => {
      send(params === undefined ? { method } : { method, params })
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
        pending.set(id, { reject, resolve: resolve as (value: unknown) => void })
        send(params === undefined ? { id, method } : { id, method, params })
      })
    }
  }
}
/* v8 ignore stop */

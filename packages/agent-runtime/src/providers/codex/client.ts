import { spawn } from "node:child_process"
import { childStdioEndpoint, makeNdjsonTransport } from "../stdio-transport.js"
import type { NdjsonTransport } from "../stdio-transport.js"

/// Minimal JSON-RPC 2.0 client over newline-delimited JSON, the codex
/// app-server's stdio transport (the `jsonrpc` header is omitted on the wire).
export interface CodexClient {
  request: <T>(method: string, params?: unknown) => Promise<T>
  notify: (method: string, params?: unknown) => void
  onNotification: (handler: (method: string, params: unknown) => void) => void
  /// Server→client requests (approvals, user-input questions). The handler's
  /// resolved value is sent back as the JSON-RPC result. The signal aborts
  /// when the connection dies with the request still unsettled: these
  /// requests block on HUMAN answers, so they routinely outlive the process
  /// (codex crashes mid-question, the session closes mid-approval) — the
  /// handler uses the signal to retract the ask instead of holding it
  /// forever, and whatever it eventually settles with is discarded rather
  /// than written to a dead pipe.
  onRequest: (
    handler: (method: string, params: unknown, signal: AbortSignal) => Promise<unknown>
  ) => void
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

/* v8 ignore start -- spawning is exercised against a live codex binary; tests drive wireCodexClient over fake endpoints. */
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
  const transport = makeNdjsonTransport(childStdioEndpoint(child), {
    exitMessage: "codex app-server exited"
  })
  const client = wireCodexClient(transport)
  return child.pid === undefined ? client : { ...client, pid: child.pid }
}
/* v8 ignore stop */

export const wireCodexClient = (transport: NdjsonTransport): CodexClient => {
  let nextId = 1
  const pending = new Map<number, Pending>()
  /// In-flight server→client requests, tracked symmetrically with `pending`:
  /// their handlers settle on human timescales (a person answering a
  /// question), so connection death must abort them — and gate their late
  /// replies — exactly as it rejects outstanding outbound requests.
  const inbound = new Map<number, AbortController>()
  let notificationHandler: ((method: string, params: unknown) => void) | undefined
  let requestHandler:
    | ((method: string, params: unknown, signal: AbortSignal) => Promise<unknown>)
    | undefined
  const closeHandlers: Array<(error: Error) => void> = []
  let closed = false

  /// The single teardown path: rejects outbound requests, aborts inbound
  /// obligations, and (for failures only) notifies close handlers.
  /// `notifyClose` is false for EXPECTED teardown (session close, agent
  /// replacement after a cwd change, short-lived listing/usage clients) so
  /// routine closes never masquerade as crashes — without this, every
  /// routine close published a "codex app-server exited" session error that
  /// clients flash before the replacement connects.
  const settle = (error: Error, notifyClose: boolean): void => {
    if (closed) return
    closed = true
    for (const entry of pending.values()) {
      entry.reject(error)
    }
    pending.clear()
    // Abort BEFORE notifying close handlers: abort listeners retract the
    // asks (dismiss question UIs) so the coarser close-time cancellation
    // that follows finds nothing left to do.
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
      // Server→client request (approvals, user-input questions).
      const handler = requestHandler
      if (handler === undefined) {
        transport.send({ error: { code: -32601, message: `No handler for ${method}` }, id })
        return
      }
      const controller = new AbortController()
      inbound.set(id, controller)
      const respond = (payload: Record<string, unknown>): void => {
        // A reply is only meaningful while its request is still live: after
        // an abort (the connection died first) the settled value is
        // discarded here — the transport's own write gate is the backstop,
        // not the primary defense.
        if (inbound.get(id) !== controller) return
        inbound.delete(id)
        transport.send(payload)
      }
      handler(method, message.params, controller.signal)
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
    notificationHandler?.(method, message.params)
  }
  transport.onLine(handleLine)

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
        pending.set(id, { reject, resolve: resolve as (value: unknown) => void })
        transport.send(params === undefined ? { id, method } : { id, method, params })
      })
    },
    ...(transport.pid === undefined ? {} : { pid: transport.pid })
  }
}

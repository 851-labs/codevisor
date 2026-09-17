import type { ChildProcessWithoutNullStreams } from "node:child_process"
import type { Readable, Writable } from "node:stream"
import { Worker } from "node:worker_threads"

import { summarizeProcessFailure } from "./process-failure.js"

/// The subset of a spawned child process a stdio transport needs. An
/// interface rather than ChildProcess itself so lifecycle RACES are unit
/// testable with in-memory streams: the transport seam is exactly where
/// write-after-exit bugs live (a reply to an approval/question resolves on
/// human timescales and routinely outlives the process), and it must not
/// require a live binary to exercise.
export interface StdioEndpoint {
  readonly stdin: Writable
  readonly stdout: Readable
  readonly stderr: Readable | undefined
  readonly pid: number | undefined
  kill: () => void
  /// Process-level termination: `error` carries a spawn/runtime process
  /// error when there is one, undefined for a plain exit.
  onExit: (handler: (error: Error | undefined) => void) => void
}

/* v8 ignore start -- thin adapter over a real child process; tests drive fake endpoints. */
export const childStdioEndpoint = (child: ChildProcessWithoutNullStreams): StdioEndpoint => ({
  kill: () => child.kill(),
  onExit: (handler) => {
    child.once("exit", () => handler(undefined))
    child.once("error", (error) => handler(error))
  },
  pid: child.pid,
  stderr: child.stderr,
  stdin: child.stdin,
  stdout: child.stdout
})
/* v8 ignore stop */

export interface NdjsonTransportOptions {
  /// Failure message when the process exits without stderr output.
  readonly exitMessage?: string
  readonly isolateCodexHistory?: boolean
}

/// A newline-delimited-JSON pipe to a child process, with an explicit
/// lifecycle. Design invariants:
///
/// - EVERY stream owned by the transport has an `error` listener from
///   construction. In Node an `'error'` event with no listener is fatal to
///   the whole process; in a multi-session server, one session's dead pipe
///   must never be able to take every other session down. Pipe errors are
///   session failures, reported through `onFailure`.
/// - Writes are lifecycle-gated. A frame addressed to a dead peer is
///   meaningless, so `send` drops it silently instead of trusting the pipe.
/// - `close()` is deliberate teardown (session close, agent replacement):
///   it gates writes and never reports a failure — routine teardown must
///   not masquerade as a crash.
export interface NdjsonTransport {
  readonly pid: number | undefined
  /// True until close() or a failure.
  isOpen: () => boolean
  /// Writes one ndjson frame; dropped silently when the transport is not
  /// open or the pipe can no longer accept writes.
  send: (payload: Record<string, unknown>) => void
  onLine: (handler: (line: string) => void) => void
  onMessage?: (handler: (message: Record<string, unknown>) => void) => void
  /// Fires at most once, only for FAILURES (process exit/crash, pipe
  /// error). Registered late, it fires immediately with the stored failure.
  onFailure: (handler: (error: Error) => void) => void
  close: () => void
}

export const makeNdjsonTransport = (
  endpoint: StdioEndpoint,
  options: NdjsonTransportOptions = {}
): NdjsonTransport => {
  let open = true
  const failureHandlers: Array<(error: Error) => void> = []
  let failure: Error | undefined
  let lineHandler: ((line: string) => void) | undefined
  let stderrTail = ""
  let messageHandler: ((message: Record<string, unknown>) => void) | undefined
  const worker =
    options.isolateCodexHistory === true
      ? new Worker(new URL("./ndjson-worker.js", import.meta.url))
      : undefined
  let pendingCharacters = 0
  let processExit: Error | undefined

  const fail = (error: Error): void => {
    // Includes deliberate close: the child's exit after close() (we killed
    // it) is expected, not a failure.
    if (!open) return
    open = false
    void worker?.terminate()
    failure = error
    for (const handler of failureHandlers) {
      handler(error)
    }
  }

  endpoint.stdin.on("error", (error: Error) => fail(error))
  endpoint.stdout.on("error", (error: Error) => fail(error))
  // stderr is capture-only; its pipe failing loses diagnostics, not the
  // session. The listener still must exist (see the invariant above).
  endpoint.stderr?.on("error", () => undefined)
  worker?.on("error", fail)
  worker?.on("exit", (code) => {
    if (open) fail(new Error(`Agent output worker exited (${code})`))
  })
  worker?.on("message", (value: { message?: Record<string, unknown>; consumed?: number }) => {
    if (!open) return
    if (value.message !== undefined) {
      if (messageHandler !== undefined) messageHandler(value.message)
      else lineHandler?.(JSON.stringify(value.message))
    }
    if (value.consumed !== undefined) {
      pendingCharacters -= value.consumed
      if (pendingCharacters < 512 * 1024) endpoint.stdout.resume()
      if (pendingCharacters === 0 && processExit !== undefined) fail(processExit)
    }
  })

  if (endpoint.stderr !== undefined) {
    endpoint.stderr.setEncoding("utf8")
    endpoint.stderr.on("data", (chunk: string) => {
      stderrTail = `${stderrTail}${chunk}`.slice(-8192)
    })
  }

  // Search each incoming chunk once. Joining only at a newline avoids the
  // quadratic flatten/rescan loop when a provider sends a huge response.
  let fragments: string[] = []
  endpoint.stdout.setEncoding("utf8")
  endpoint.stdout.on("data", (chunk: string) => {
    if (!open) return
    if (worker !== undefined) {
      pendingCharacters += chunk.length
      worker.postMessage({ chunk }, [])
      if (pendingCharacters >= 1024 * 1024) endpoint.stdout.pause()
      return
    }
    let start = 0
    while (start < chunk.length) {
      const newline = chunk.indexOf("\n", start)
      if (newline === -1) break
      fragments.push(chunk.slice(start, newline))
      const line = fragments.join("")
      fragments = []
      start = newline + 1
      lineHandler?.(line)
    }
    if (start < chunk.length) fragments.push(chunk.slice(start))
  })

  endpoint.onExit((error) => {
    // The captured tail is raw CLI output — often minified bundle text and
    // stack frames — and this error surfaces to the user, so condense it.
    processExit =
      error ??
      new Error(summarizeProcessFailure(stderrTail, options.exitMessage ?? "process exited"))
    if (pendingCharacters === 0) fail(processExit)
  })

  return {
    close: () => {
      open = false
      fragments = []
      void worker?.terminate()
      try {
        endpoint.stdin.end()
      } catch {
        // Already-destroyed pipe: teardown proceeds regardless.
      }
      endpoint.kill()
    },
    isOpen: () => open,
    onFailure: (handler) => {
      if (failure !== undefined) {
        handler(failure)
        return
      }
      failureHandlers.push(handler)
    },
    onLine: (handler) => {
      lineHandler = handler
    },
    ...(worker === undefined
      ? {}
      : {
          onMessage: (handler: (message: Record<string, unknown>) => void) => {
            messageHandler = handler
          }
        }),
    pid: endpoint.pid,
    send: (payload) => {
      if (!open) return
      if (endpoint.stdin.destroyed || endpoint.stdin.writableEnded) return
      try {
        endpoint.stdin.write(`${JSON.stringify(payload)}\n`)
      } catch (error) {
        fail(error instanceof Error ? error : new Error(String(error)))
      }
    }
  }
}

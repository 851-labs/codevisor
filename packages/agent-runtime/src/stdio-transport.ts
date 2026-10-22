import type { ChildProcessWithoutNullStreams } from "node:child_process"
import type { Readable, Writable } from "node:stream"
import { Worker } from "node:worker_threads"

import { summarizeProcessFailure } from "./process-failure.js"

export interface StdioEndpoint {
  readonly stdin: Writable
  readonly stdout: Readable
  readonly stderr: Readable | undefined
  kill: () => void
  onExit: (handler: (error: Error | undefined) => void) => void
}

/* v8 ignore start */
export const childStdioEndpoint = (child: ChildProcessWithoutNullStreams): StdioEndpoint => ({
  kill: () => child.kill(),
  onExit: (handler) => {
    child.once("exit", () => handler(undefined))
    child.once("error", (error) => handler(error))
  },
  stderr: child.stderr,
  stdin: child.stdin,
  stdout: child.stdout
})
/* v8 ignore stop */

export interface NdjsonTransportOptions {
  readonly exitMessage?: string
  readonly isolateCodexHistory?: boolean
}

export interface NdjsonTransport {
  isOpen: () => boolean
  send: (payload: Record<string, unknown>) => void
  onLine: (handler: (line: string) => void) => void
  onMessage?: (handler: (message: Record<string, unknown>) => void) => void
  onFailure: (handler: (error: Error) => void) => void
  close: () => void
}

const startNdjsonWorkerIfIsolated = (options: NdjsonTransportOptions): Worker | undefined => {
  if (options.isolateCodexHistory !== true) return undefined
  return new Worker(new URL("./ndjson-worker.js", import.meta.url))
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
  const worker = startNdjsonWorkerIfIsolated(options)
  let pendingCharacters = 0
  let processExit: Error | undefined

  const fail = (error: Error): void => {
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
      } catch {}
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

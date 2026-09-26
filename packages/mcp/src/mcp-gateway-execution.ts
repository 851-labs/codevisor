import { createHash } from "node:crypto"

import type { RuntimeEventSink } from "@codevisor/agent-runtime"
import {
  canonicalExecutionArgs,
  CODEVISOR_EXECUTION_MAX_CALLS,
  CODEVISOR_EXECUTION_MAX_ERROR,
  CODEVISOR_EXECUTION_MAX_STATUS,
  type CodevisorExecutionCall,
  type CodevisorExecutionState
} from "@codevisor/api"

/// Live transcript annotation for one `execute` call: the latest `status()`
/// text and every nested tool call, streamed to the session sink so the
/// server can attach them to the harness tool row. None of this reaches the
/// model's result.

export const EXECUTION_EMIT_INTERVAL_MS = 250

export interface ExecutionTimers {
  readonly now: () => number
  readonly setTimeout: (callback: () => void, ms: number) => unknown
  readonly clearTimeout: (handle: unknown) => void
}

const systemTimers: ExecutionTimers = {
  now: () => performance.now(),
  setTimeout: (callback, ms) => setTimeout(callback, ms),
  clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>)
}

export const truncateText = (text: string, max: number): string => {
  const collapsed = text.replace(/\s+/g, " ").trim()
  return collapsed.length <= max ? collapsed : `${collapsed.slice(0, max - 1).trimEnd()}…`
}

/// The message a person needs from a thrown error: its first line, without
/// the "Error:" prefix or the stack frames the sandbox appends.
export const errorSummary = (error: string, max: number): string => {
  const firstLine = error.split("\n").find((line) => line.trim().length > 0) ?? error
  const message = firstLine
    .replace(/^\s*(?:[A-Za-z]*Error:\s*)+/, "")
    .replace(/\s+at\s+(?:<anonymous>|[\w$.]+\s*\(|file:|node:).*$/, "")
  return truncateText(message.length > 0 ? message : firstLine, max)
}

/// sha256 hex of the canonical execute arguments, exactly as received.
export const executionArgsHash = (args: {
  readonly code: string
  readonly description: string
}): string => createHash("sha256").update(canonicalExecutionArgs(args)).digest("hex")

export interface ExecutionRecorder {
  readonly status: (text: string) => void
  readonly call: (call: CodevisorExecutionCall) => void
  /// Emits the terminal state and resolves once the sink has taken it.
  readonly finish: (error?: string) => Promise<void>
}

export const makeExecutionRecorder = (options: {
  readonly sink: RuntimeEventSink | undefined
  readonly sessionId: string
  readonly argsHash: string
  readonly timers?: ExecutionTimers
}): ExecutionRecorder => {
  const { sink, sessionId, argsHash } = options
  const timers = options.timers ?? systemTimers
  const calls: Array<CodevisorExecutionCall> = []
  let status: string | undefined
  let lastEmitAt = Number.NEGATIVE_INFINITY
  let pending: unknown
  let finished = false
  let delivery: Promise<void> = Promise.resolve()

  const emit = (state: CodevisorExecutionState["state"], error?: string): void => {
    lastEmitAt = timers.now()
    if (sink === undefined) return
    const execution: CodevisorExecutionState = {
      state,
      ...(status === undefined ? {} : { status }),
      calls: [...calls],
      ...(error === undefined ? {} : { error })
    }
    const event = {
      kind: "session.output" as const,
      subjectId: sessionId,
      payload: { kind: "codevisor_execution", argsHash, execution }
    }
    // Hand events to the sink in emission order (the session sink queues
    // them serially); an annotation failure never fails the script.
    let delivered: Promise<unknown>
    try {
      delivered = Promise.resolve(sink(event))
    } catch (cause) {
      delivered = Promise.reject(cause)
    }
    const previous = delivery
    delivery = Promise.all([previous, delivered]).then(
      () => undefined,
      () => undefined
    )
  }

  const scheduleRunning = (): void => {
    if (finished || pending !== undefined) return
    const wait = lastEmitAt + EXECUTION_EMIT_INTERVAL_MS - timers.now()
    if (wait <= 0) {
      emit("running")
      return
    }
    // finish() cancels this timer, so it only fires mid-execution.
    pending = timers.setTimeout(() => {
      pending = undefined
      emit("running")
    }, wait)
  }

  emit("running")

  return {
    status: (text) => {
      const trimmed = truncateText(text, CODEVISOR_EXECUTION_MAX_STATUS)
      status = trimmed.length === 0 ? undefined : trimmed
      scheduleRunning()
    },
    call: (call) => {
      calls.push(
        call.error === undefined
          ? call
          : { ...call, error: errorSummary(call.error, CODEVISOR_EXECUTION_MAX_ERROR) }
      )
      if (calls.length > CODEVISOR_EXECUTION_MAX_CALLS) calls.shift()
      scheduleRunning()
    },
    finish: async (error) => {
      if (!finished) {
        finished = true
        if (pending !== undefined) timers.clearTimeout(pending)
        pending = undefined
        emit(
          error === undefined ? "completed" : "failed",
          error === undefined ? undefined : errorSummary(error, CODEVISOR_EXECUTION_MAX_ERROR)
        )
      }
      await delivery
    }
  }
}

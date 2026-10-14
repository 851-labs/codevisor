import type { TerminalCreateResponse, TerminalServerFrame } from "@codevisor/api"
import { Effect } from "effect"

import type { ReplayBuffer } from "./replay-buffer.js"
import type { SizeArbiter } from "./size-arbiter.js"
import type { TerminalProcess } from "./types.js"
import { TerminalError } from "./types.js"
import type { VtTerminal } from "./vt/ghostty-vt.js"

export interface RunningTerminal {
  readonly terminalId: string
  readonly sessionId: string
  readonly process: TerminalProcess
  readonly sinks: Set<(frame: TerminalServerFrame) => void>
  readonly frames: ReplayBuffer
  readonly clientSeqs: Map<string, number>
  readonly screen: VtTerminal
  readonly sizes: SizeArbiter
  exitFrame?: Extract<TerminalServerFrame, { type: "exit" }>
  removed: boolean
  nextOutputSeq: number
  closed: boolean
  readonly external: boolean
}

export type TerminalFramePayload =
  | { readonly type: "output"; readonly data: string }
  | { readonly type: "exit"; readonly exitCode?: number }

/* v8 ignore start */
export const noopProcess: TerminalProcess = {
  write: () => undefined,
  resize: () => undefined,
  kill: () => undefined
}
/* v8 ignore stop */

export const terminalAttempt = <A>(
  operation: string,
  run: () => A
): Effect.Effect<A, TerminalError> =>
  Effect.try({
    try: run,
    catch: (cause) =>
      cause instanceof TerminalError
        ? cause
        : new TerminalError({
            operation,
            message: cause instanceof Error ? cause.message : String(cause)
          })
  })

export const terminalPromise = <A>(
  operation: string,
  run: () => Promise<A>
): Effect.Effect<A, TerminalError> =>
  Effect.tryPromise({
    try: run,
    catch: (cause) =>
      cause instanceof TerminalError
        ? cause
        : new TerminalError({
            operation,
            message: cause instanceof Error ? cause.message : String(cause)
          })
  })

export const terminalResponse = (terminal: RunningTerminal): TerminalCreateResponse => ({
  terminalId: terminal.terminalId,
  websocketPath: `/v1/terminals/${terminal.terminalId}/socket`,
  nextOutputSeq: terminal.nextOutputSeq
})

export type SequencedFrame = Extract<TerminalServerFrame, { type: "output" | "exit" }>

export const sequenceFrame = (seq: number, frame: TerminalFramePayload): SequencedFrame => {
  switch (frame.type) {
    case "output": {
      return { type: "output", seq, data: frame.data }
    }
    case "exit": {
      return frame.exitCode === undefined
        ? { type: "exit", seq }
        : { type: "exit", seq, exitCode: frame.exitCode }
    }
  }
}

export const isDuplicateClientFrame = (
  terminal: RunningTerminal,
  clientId: string,
  clientSeq: number
): boolean => {
  const lastSeq = terminal.clientSeqs.get(clientId)
  return lastSeq !== undefined && clientSeq <= lastSeq
}

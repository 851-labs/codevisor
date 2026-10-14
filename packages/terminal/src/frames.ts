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
  /// Byte-bounded replay for reconnecting clients; see ReplayBuffer.
  readonly frames: ReplayBuffer
  readonly clientSeqs: Map<string, number>
  /// Authoritative screen state, fed every output frame.
  readonly screen: VtTerminal
  /// Which client's size the PTY follows when several are attached.
  readonly sizes: SizeArbiter
  /// The exit frame once the process ended, replayed after a resync.
  exitFrame?: Extract<TerminalServerFrame, { type: "exit" }>
  /// Set once the terminal left the manager and its screen was freed; late
  /// output from a caller-owned process is still sequenced but not parsed.
  removed: boolean
  nextOutputSeq: number
  closed: boolean
  /// Externally-managed terminals are never (re)spawned by the manager and
  /// stay attachable after exit (scrollback survives until removed).
  readonly external: boolean
}

export type TerminalFramePayload =
  | { readonly type: "output"; readonly data: string }
  | { readonly type: "exit"; readonly exitCode?: number }

/// Stand-in process for restored terminals: the real process died with the
/// previous server, and restored terminals are closed, so nothing routes here.
/* v8 ignore start -- restored terminals are closed; no code path reaches the stand-in process. */
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

/// The frames a terminal's own output produces (errors are per-client).
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

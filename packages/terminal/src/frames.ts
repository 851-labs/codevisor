import type { TerminalCreateResponse, TerminalServerFrame } from "@codevisor/api"
import { Effect } from "effect"

import type { TerminalProcess } from "./types.js"
import { TerminalError } from "./types.js"

/// External terminals can outlive any single client and stream indefinitely
/// (dev servers); cap the replay buffer so memory stays bounded. Clients that
/// reconnect past the trim point lose the oldest scrollback only.
export const EXTERNAL_TERMINAL_MAX_FRAMES = 20_000

export interface RunningTerminal {
  readonly terminalId: string
  readonly sessionId: string
  readonly process: TerminalProcess
  readonly sinks: Set<(frame: TerminalServerFrame) => void>
  readonly frames: Array<TerminalServerFrame>
  readonly clientSeqs: Map<string, number>
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

export const terminalResponse = (terminal: RunningTerminal): TerminalCreateResponse => ({
  terminalId: terminal.terminalId,
  websocketPath: `/v1/terminals/${terminal.terminalId}/socket`,
  nextOutputSeq: terminal.nextOutputSeq
})

export const sequenceFrame = (seq: number, frame: TerminalFramePayload): TerminalServerFrame => {
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

import type { Options as ClaudeOptions } from "@anthropic-ai/claude-agent-sdk"
import { runtimeError } from "@codevisor/agent-runtime"

import type { ClaudeQuery, ClaudeQueryFn, ClaudeSession } from "./session.js"
import { applyStreamMessage } from "./stream-messages.js"
import { resumeSessionAfterStreamDeath } from "./stream-recovery.js"
import { failDeferredPrompts, finishActiveTurn, type TurnEnding } from "./turn-lifecycle.js"

export interface StreamPumpDeps {
  readonly options: ClaudeOptions
  readonly queryFn: ClaudeQueryFn
  readonly readFile: (path: string) => string | undefined
}

export type StreamPump = (query: ClaudeQuery) => Promise<void>

const UNEXPECTED_END_DETAIL = "The Claude connection ended unexpectedly."

export const makeStreamPump = (session: ClaudeSession, deps: StreamPumpDeps): StreamPump => {
  const { options, queryFn, readFile } = deps

  const resumeAfterStreamDeath = (): Promise<boolean> =>
    resumeSessionAfterStreamDeath(session, {
      options,
      pump,
      queryFn
    })

  const pump = async (query: ClaudeQuery): Promise<void> => {
    let streamFailure: string | undefined
    try {
      for await (const message of query) applyStreamMessage(session, message, readFile)
    } catch (cause) {
      streamFailure = streamFailureText(cause)
      if (isIdle(session)) failIdleSession(session, cause, streamFailure)
    } finally {
      if (session.q === query) session.streamEnded = true
      if (endedMidTurn(session, query)) {
        if (session.interruptRequested) {
          await finishActiveTurn(session, "cancelled")
        } else if (!(await resumeAfterStreamDeath())) {
          await finishActiveTurn(session, "end_turn", unexpectedEnding(streamFailure))
        }
      }
    }
  }
  return pump
}

const streamFailureText = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

const isIdle = (session: ClaudeSession): boolean => !session.turnActive && !session.retired

const failIdleSession = (session: ClaudeSession, cause: unknown, failure: string): void => {
  session.pendingPrompt?.reject(runtimeError("prompt", cause))
  session.pendingPrompt = undefined
  failDeferredPrompts(session, runtimeError("prompt", cause))
  void session.emit({
    kind: "session.error",
    payload: { message: failure },
    subjectId: session.key
  })
}

const endedMidTurn = (session: ClaudeSession, query: ClaudeQuery): boolean =>
  session.q === query && session.turnActive

const unexpectedEnding = (streamFailure: string | undefined): TurnEnding => ({
  retryable: true,
  stopDetail: streamFailure ?? UNEXPECTED_END_DETAIL
})

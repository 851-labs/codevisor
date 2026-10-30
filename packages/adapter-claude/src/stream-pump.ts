import type { Options as ClaudeOptions } from "@anthropic-ai/claude-agent-sdk"
import { redactSecrets, runtimeError } from "@codevisor/agent-runtime"

import type { ClaudeQuery, ClaudeQueryFn, ClaudeSession } from "./session.js"
import { applyStreamMessage } from "./stream-messages.js"
import { resumeSessionAfterStreamDeath } from "./stream-recovery.js"
import { reportRuntimeState } from "./system-messages.js"
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
      if (isIdle(session)) failIdlePrompts(session, cause)
    } finally {
      if (session.q === query) endStream(session, streamFailure)
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

const endStream = (session: ClaudeSession, failure: string | undefined): void => {
  session.streamEnded = true
  if (!session.retired && !session.abort.signal.aborted) logProcessEnd(session, failure)
  if (session.runtimeState !== "idle") reportRuntimeState(session, "idle")
}

const logProcessEnd = (session: ClaudeSession, failure: string | undefined): void => {
  console.error(
    JSON.stringify({
      event: "claude_process_ended",
      sessionId: session.key,
      turnActive: session.turnActive,
      failure: failure === undefined ? null : redactSecrets(failure)
    })
  )
}

const streamFailureText = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

const isIdle = (session: ClaudeSession): boolean =>
  !session.turnActive && !session.retired && session.startupFailure === undefined

const failIdlePrompts = (session: ClaudeSession, cause: unknown): void => {
  session.pendingPrompt?.reject(runtimeError("prompt", cause))
  session.pendingPrompt = undefined
  failDeferredPrompts(session, runtimeError("prompt", cause))
}

const endedMidTurn = (session: ClaudeSession, query: ClaudeQuery): boolean =>
  session.q === query && session.turnActive

const unexpectedEnding = (streamFailure: string | undefined): TurnEnding => ({
  retryable: true,
  stopDetail: streamFailure ?? UNEXPECTED_END_DETAIL
})

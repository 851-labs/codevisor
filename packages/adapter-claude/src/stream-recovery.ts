import type { Options as ClaudeOptions, Query } from "@anthropic-ai/claude-agent-sdk"

import { emitBackgroundTasks } from "./background-tasks.js"
import { cancelClaudePendingQuestions } from "./questions.js"
import { InputQueue, type ClaudeQueryFn, type ClaudeSession } from "./session.js"
import { pushResumeAfterInterruptionPrompt } from "./turn-recovery.js"

/// Invisible stream resumptions allowed per turn. The SDK stream ending with a
/// turn still open and no `result` means the CLI process or its pipe died, not
/// that the work finished: resume the same CLI session on a fresh query and
/// nudge it to continue — what a user would do by hand — instead of ending the
/// turn with an error the user can do nothing about. Past the cap the turn
/// ends and surfaces the failure.
const MAX_STREAM_RECOVERIES = 2

export interface StreamRecoveryDeps {
  /// Delay before the first resumption; doubles per attempt.
  readonly backoffMs: number
  /// The options the session's first query was started with.
  readonly options: ClaudeOptions
  /// Starts the message pump for a query (the session's own pump).
  readonly pump: (query: Query) => Promise<void>
  readonly queryFn: ClaudeQueryFn
}

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => {
    setTimeout(resolve, ms)
  })

/// Resumes the live turn on a fresh SDK query after the stream died with the
/// turn still open. The CLI session is resumed by id (its transcript is
/// durable on disk), a new input queue replaces the one the dead query may
/// still be reading, and an interruption-aware nudge restarts the model.
/// Returns false when the session cannot be resumed (retired, aborted,
/// cancelled, or out of attempts) so the caller ends the turn instead.
export const resumeSessionAfterStreamDeath = async (
  session: ClaudeSession,
  deps: StreamRecoveryDeps
): Promise<boolean> => {
  if (session.retired || session.abort.signal.aborted || session.interruptRequested) return false
  if (session.streamRecoveries >= MAX_STREAM_RECOVERIES) return false
  const attempt = session.streamRecoveries
  session.streamRecoveries += 1
  await sleep(deps.backoffMs * 2 ** attempt)
  // The session may have been retired or cancelled while backing off.
  if (session.retired || session.abort.signal.aborted || !session.turnActive) return false
  // State that died with the CLI process: a permission/question picker whose
  // resolver belonged to the dead query, and background tasks whose child
  // processes went down with it. The resumed CLI re-asks anything it needs.
  void cancelClaudePendingQuestions(session)
  if (session.backgroundTasks.size > 0 || session.backgroundShellKeys.size > 0) {
    session.backgroundTasks.clear()
    session.backgroundShellKeys.clear()
    emitBackgroundTasks(session)
  }
  // A fresh session was started with `--session-id`; the resumed one must
  // name the same id through `resume` instead, never both.
  const { extraArgs: _fresh, ...resumeOptions } = deps.options
  const nextInput = new InputQueue()
  session.input.end()
  session.input = nextInput
  session.streamEnded = false
  session.q = deps.queryFn({
    prompt: nextInput,
    options: { ...resumeOptions, resume: session.sdkSessionId }
  })
  deps.pump(session.q).catch(() => undefined)
  pushResumeAfterInterruptionPrompt(session)
  return true
}

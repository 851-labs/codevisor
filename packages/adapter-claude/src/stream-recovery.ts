import type { Options as ClaudeOptions, Query } from "@anthropic-ai/claude-agent-sdk"

import { emitBackgroundTasks } from "./background-tasks.js"
import { claudeStartOptions } from "./models.js"
import { cancelClaudePendingQuestions } from "./questions.js"
import { InputQueue, type ClaudeQueryFn, type ClaudeSession } from "./session.js"
import { pushResumeAfterInterruptionPrompt } from "./turn-recovery.js"

const MAX_STREAM_RECOVERIES = 2
const STREAM_RECOVERY_BACKOFF_MS = 1_000

export interface StreamRecoveryDeps {
  readonly options: ClaudeOptions
  readonly pump: (query: Query) => Promise<void>
  readonly queryFn: ClaudeQueryFn
}

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => {
    setTimeout(resolve, ms)
  })

export const resumeSessionAfterStreamDeath = async (
  session: ClaudeSession,
  deps: StreamRecoveryDeps
): Promise<boolean> => {
  if (session.retired || session.abort.signal.aborted || session.interruptRequested) return false
  if (session.streamRecoveries >= MAX_STREAM_RECOVERIES) return false
  const attempt = session.streamRecoveries
  session.streamRecoveries += 1
  await sleep(STREAM_RECOVERY_BACKOFF_MS * 2 ** attempt)
  if (session.retired || session.abort.signal.aborted || !session.turnActive) return false
  void cancelClaudePendingQuestions(session)
  if (session.backgroundTasks.size > 0) {
    session.backgroundTasks.clear()
    void emitBackgroundTasks(session)
  }
  const {
    extraArgs: startArgs,
    model: _startModel,
    settings: startSettings,
    ...resumeOptions
  } = deps.options
  const { "session-id": _fresh, ...keptArgs } = startArgs ?? {}
  const nextInput = new InputQueue()
  session.input.end()
  session.input = nextInput
  session.streamEnded = false
  session.q = deps.queryFn({
    prompt: nextInput,
    options: {
      ...resumeOptions,
      ...(Object.keys(keptArgs).length === 0 ? {} : { extraArgs: keptArgs }),
      ...claudeStartOptions({
        effort: session.currentEffort,
        model: session.currentModel,
        speed: session.currentSpeed,
        ...(typeof startSettings === "object" && startSettings.skillOverrides !== undefined
          ? { skillOverrides: startSettings.skillOverrides }
          : {})
      }),
      resume: session.sdkSessionId
    }
  })
  deps.pump(session.q).catch(() => undefined)
  pushResumeAfterInterruptionPrompt(session)
  return true
}

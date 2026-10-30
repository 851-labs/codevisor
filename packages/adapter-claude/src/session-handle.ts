import {
  adapterPromise,
  normalizePromptInput,
  type AgentSessionHandle,
  type CancelResult,
  type SetGoalUpdate
} from "@codevisor/agent-runtime"
import { isoTimestamp, type SessionGoal } from "@codevisor/api"

import { claudeContent } from "./attachments.js"
import { readBackgroundTaskOutput } from "./background-task-output.js"
import { emitBackgroundTasks } from "./background-tasks.js"
import { pauseGoalForForcedCancellation, pushGoalCommand } from "./goals.js"
import { deferred } from "./internal.js"
import {
  effortLevelsFor,
  isPermissionMode,
  metadataFor,
  resolveRequestedClaudeModel,
  supportsFastMode
} from "./models.js"
import {
  answerClaudeQuestion,
  cancelClaudePendingQuestions,
  replyToClaudeQuestion
} from "./questions.js"
import { endSessionRequest } from "./restart-resume.js"
import { claudeSessionContextFrom } from "./session-context.js"
import type { ClaudeSession } from "./session.js"
import { retiredError, startupError } from "./startup-failure.js"
import {
  ensureObservedTurnStarted,
  ensureTurnStarted,
  failDeferredPrompts,
  finishActiveTurn
} from "./turn-lifecycle.js"

const CANCEL_GRACE_MS = 1_500

const goalSubcommand = (update: SetGoalUpdate) => {
  if (update.status === "paused") return "pause"
  if (update.status === "active") return "resume"
  return undefined
}

interface TurnStop {
  readonly request: () => Promise<unknown>
  readonly keepsProcess: boolean
  readonly retired: CancelResult
}

const interruptTurn = (session: ClaudeSession): TurnStop => ({
  request: () => session.q.interrupt(),
  keepsProcess: true,
  retired: { runtimeState: "retire" }
})

const pauseForRestart = (session: ClaudeSession): Promise<CancelResult> => {
  const endSession = session.resumesInterruptedTurns ? endSessionRequest(session.q) : undefined
  if (endSession === undefined) return stopTurn(session, interruptTurn)

  return stopTurn(session, () => ({
    request: endSession,
    keepsProcess: false,
    retired: { runtimeState: "retire", resumesInterruptedTurn: true }
  }))
}

const stopTurn = async (
  session: ClaudeSession,
  stopFor: (session: ClaudeSession) => TurnStop
): Promise<CancelResult> => {
  if (session.cancelInFlight !== undefined) return session.cancelInFlight
  const cancellation = (async (): Promise<CancelResult> => {
    if (!session.turnActive && session.pendingUserCommands > 0) {
      await ensureObservedTurnStarted(session)
    }
    const capturedTurnId = session.turnId
    const capturedCompletion = session.turnCompletion
    const questionsCancelled = cancelClaudePendingQuestions(session)
    if (!session.turnActive) {
      await questionsCancelled
      await capturedCompletion?.promise
      return { runtimeState: "reusable" }
    }

    const stop = stopFor(session)
    session.interruptRequested = true
    let timeout: ReturnType<typeof setTimeout> | undefined
    const timedOut = new Promise<"timeout">((resolvePromise) => {
      timeout = setTimeout(() => resolvePromise("timeout"), CANCEL_GRACE_MS)
    })
    const stopFailed = Promise.resolve()
      .then(stop.request)
      .then(
        () => new Promise<never>(() => undefined),
        () => Promise.resolve("stopFailed" as const)
      )
    const settled = capturedCompletion?.promise.then(() => "settled" as const)
    const outcome = await Promise.race([
      ...(settled === undefined ? [] : [settled]),
      stopFailed,
      timedOut
    ])
    if (timeout !== undefined) clearTimeout(timeout)
    await questionsCancelled

    if (
      stop.keepsProcess &&
      outcome !== "stopFailed" &&
      (outcome === "settled" || !session.turnActive || session.turnId !== capturedTurnId) &&
      !session.streamEnded
    ) {
      await capturedCompletion?.promise
      return { runtimeState: "reusable" }
    }

    session.retired = true
    failDeferredPrompts(session, retiredError())
    if (session.backgroundTasks.size > 0) {
      session.backgroundTasks.clear()
      await emitBackgroundTasks(session)
    }
    await pauseGoalForForcedCancellation(session)
    if (session.turnActive && session.turnId === capturedTurnId) {
      await finishActiveTurn(session, "cancelled")
    } else {
      await capturedCompletion?.promise
    }
    session.input.end()
    session.abort.abort()
    return outcome === "stopFailed" ? { runtimeState: "retire" } : stop.retired
  })()
  session.cancelInFlight = cancellation
  try {
    return await cancellation
  } finally {
    if (session.cancelInFlight === cancellation) {
      session.cancelInFlight = undefined
    }
  }
}

export const claudeSessionHandle = (session: ClaudeSession): AgentSessionHandle => ({
  exited: () => session.streamEnded && !session.turnActive,
  cancel: adapterPromise("cancel", () => stopTurn(session, interruptTurn)),
  pauseForRestart: adapterPromise("pauseForRestart", () => pauseForRestart(session)),
  close: adapterPromise("close", async () => {
    session.retired = true
    failDeferredPrompts(session, retiredError())
    await cancelClaudePendingQuestions(session)
    session.input.end()
    session.abort.abort()
  }),
  prompt: (input) =>
    adapterPromise("prompt", async () => {
      const cancellation = session.cancelInFlight
      if (cancellation !== undefined) {
        const result = await cancellation
        if (result.runtimeState === "retire") {
          throw retiredError()
        }
      }
      if (session.retired) {
        throw retiredError()
      }
      const pending = deferred<{ stopReason: string }>()
      if (session.turnActive) {
        session.deferredPrompts.push({ input, pending })
        return pending.promise
      }
      if (session.streamEnded) throw startupError(session)
      session.pendingPrompt = pending
      await ensureTurnStarted(session, "user")
      session.input.push({
        message: { content: claudeContent(normalizePromptInput(input)), role: "user" },
        parent_tool_use_id: null,
        session_id: session.sdkSessionId,
        type: "user"
      })
      return pending.promise
    }),
  steer: (input) =>
    adapterPromise("steer", async () => {
      if (
        !session.turnActive ||
        session.retired ||
        session.streamEnded ||
        session.interruptRequested ||
        session.cancelInFlight !== undefined
      ) {
        return false
      }
      session.input.push({
        message: { content: claudeContent(normalizePromptInput(input)), role: "user" },
        parent_tool_use_id: null,
        priority: "next",
        session_id: session.sdkSessionId,
        type: "user"
      })
      return true
    }),
  setConfigOption: (configId, value) =>
    adapterPromise("setConfigOption", async () => {
      if (configId === "model") {
        const model = resolveRequestedClaudeModel(session, value)
        await session.q.setModel(model)
        session.currentModel = model
        session.onDefaultModel = false
        if (!session.effortPicked) {
          await followModelDefaultEffort(session)
        } else if (!effortLevelsFor(session).includes(session.currentEffort)) {
          session.currentEffort = "default"
          session.effortPicked = false
        }
        if (session.currentSpeed === "fast" && !supportsFastMode(session)) {
          await session.q.applyFlagSettings({ fastMode: false })
          session.currentSpeed = "standard"
        }
      } else if (configId === "effort") {
        const flags: Record<string, unknown> = { effortLevel: value === "default" ? null : value }
        await session.q.applyFlagSettings(flags)
        session.currentEffort = value
        session.effortPicked = value !== "default"
      } else if (configId === "speed") {
        await session.q.applyFlagSettings({ fastMode: value === "fast" })
        session.currentSpeed = value === "fast" ? "fast" : "standard"
      } else {
        throw new Error(`Unknown config option: ${configId}`)
      }
      const configOptions = metadataFor(session).configOptions
      await session.emit({
        kind: "session.updated",
        payload: {
          configId,
          configOptions,
          value
        },
        subjectId: session.key
      })
      return configOptions
    }),
  setMode: (modeId) =>
    adapterPromise("setMode", async () => {
      if (!isPermissionMode(modeId)) throw new Error(`Unknown mode: ${modeId}`)
      await session.q.setPermissionMode(modeId)
      session.currentModeId = modeId
      await session.emit({
        kind: "session.updated",
        payload: { modeId },
        subjectId: session.key
      })
    }),
  answerQuestion: (questionId, answer) =>
    adapterPromise("answerQuestion", () => answerClaudeQuestion(session, questionId, answer)),
  replyToQuestion: (questionId, reply) =>
    adapterPromise("replyToQuestion", () => replyToClaudeQuestion(session, questionId, reply)),
  setGoal: (update) =>
    adapterPromise("setGoal", async () => {
      if (update.objective !== undefined) {
        pushGoalCommand(session, `/goal ${update.objective}`)
        const goal: SessionGoal = {
          createdAt: session.currentGoal?.createdAt ?? isoTimestamp(),
          objective: update.objective,
          status: "active",
          timeUsedSeconds: 0,
          tokenBudget: null,
          tokensUsed: 0,
          updatedAt: isoTimestamp()
        }
        session.currentGoal = goal
        await session.emit({
          kind: "session.updated",
          payload: { goal },
          subjectId: session.key
        })
        return goal
      }
      const current = session.currentGoal
      if (current === undefined) {
        throw new Error("No active goal to update")
      }
      const subcommand = goalSubcommand(update)
      if (subcommand === undefined) {
        throw new Error("Claude goal updates support objective, pause, and resume only")
      }
      pushGoalCommand(session, `/goal ${subcommand}`)
      const goal: SessionGoal = { ...current, status: update.status!, updatedAt: isoTimestamp() }
      session.currentGoal = goal
      await session.emit({
        kind: "session.updated",
        payload: { goal },
        subjectId: session.key
      })
      return goal
    }),
  clearGoal: adapterPromise("clearGoal", async () => {
    pushGoalCommand(session, "/goal clear")
    session.currentGoal = undefined
    await session.emit({
      kind: "session.updated",
      payload: { goalCleared: true },
      subjectId: session.key
    })
  }),
  stopTask: (taskId) => adapterPromise("stopTask", () => session.q.stopTask(taskId)),
  readTaskOutput: (taskId, lineLimit) =>
    adapterPromise("readTaskOutput", () => readBackgroundTaskOutput(session, taskId, lineLimit)),
  readContext: adapterPromise("readContext", async () =>
    claudeSessionContextFrom(await session.q.getContextUsage())
  )
})

const followModelDefaultEffort = async (session: ClaudeSession): Promise<void> => {
  const effort = session.effortDefaults.get(session.currentModel) ?? "default"
  if (effort === session.currentEffort) return

  const flags: Record<string, unknown> = { effortLevel: effort === "default" ? null : effort }
  await session.q.applyFlagSettings(flags)
  session.currentEffort = effort
}

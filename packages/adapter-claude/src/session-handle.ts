import type { Query } from "@anthropic-ai/claude-agent-sdk"
import {
  adapterPromise,
  normalizePromptInput,
  type AgentSessionHandle,
  type CancelResult
} from "@codevisor/agent-runtime"
import { isoTimestamp, type SessionGoal } from "@codevisor/api"

import { claudeContent } from "./attachments.js"
import { emitBackgroundTasks } from "./background-tasks.js"
import { pauseGoalForForcedCancellation, pushGoalCommand } from "./goals.js"
import { deferred } from "./internal.js"
import {
  effortLevelsFor,
  metadataFor,
  resolveRequestedClaudeModel,
  supportsFastMode
} from "./models.js"
import { answerClaudeQuestion, cancelClaudePendingQuestions } from "./questions.js"
import type { ClaudeSession } from "./session.js"
import {
  ensureObservedTurnStarted,
  ensureTurnStarted,
  failDeferredPrompts,
  finishActiveTurn
} from "./turn-lifecycle.js"

const CANCEL_GRACE_MS = 1_500

export const claudeSessionHandle = (session: ClaudeSession): AgentSessionHandle => ({
  cancel: adapterPromise("cancel", async () => {
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

      session.interruptRequested = true
      let timeout: ReturnType<typeof setTimeout> | undefined
      const timedOut = new Promise<"timeout">((resolvePromise) => {
        timeout = setTimeout(() => resolvePromise("timeout"), CANCEL_GRACE_MS)
      })
      const interruptFailed = Promise.resolve()
        .then(() => session.q.interrupt())
        .then(
          () => new Promise<never>(() => undefined),
          () => Promise.resolve("interruptFailed" as const)
        )
      const settled = capturedCompletion?.promise.then(() => "settled" as const)
      const outcome = await Promise.race([
        ...(settled === undefined ? [] : [settled]),
        interruptFailed,
        timedOut
      ])
      if (timeout !== undefined) clearTimeout(timeout)
      await questionsCancelled

      if (
        outcome !== "interruptFailed" &&
        (outcome === "settled" || !session.turnActive || session.turnId !== capturedTurnId) &&
        !session.streamEnded
      ) {
        await capturedCompletion?.promise
        return { runtimeState: "reusable" }
      }

      session.retired = true
      failDeferredPrompts(session, new Error("Claude runtime was retired"))
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
      return { runtimeState: "retire" }
    })()
    session.cancelInFlight = cancellation
    try {
      return await cancellation
    } finally {
      if (session.cancelInFlight === cancellation) {
        session.cancelInFlight = undefined
      }
    }
  }),
  close: adapterPromise("close", async () => {
    session.retired = true
    failDeferredPrompts(session, new Error("Claude runtime was retired"))
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
          throw new Error("Claude runtime was retired")
        }
      }
      if (session.retired) {
        throw new Error("Claude runtime was retired")
      }
      const pending = deferred<{ stopReason: string }>()
      if (session.turnActive) {
        session.deferredPrompts.push({ input, pending })
        return pending.promise
      }
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
  setConfigOption: (configId, value) =>
    adapterPromise("setConfigOption", async () => {
      if (configId === "model") {
        const model = resolveRequestedClaudeModel(session, value)
        await session.q.setModel(model)
        session.currentModel = model
        if (!effortLevelsFor(session).includes(session.currentEffort)) {
          session.currentEffort = "default"
        }
        if (session.currentSpeed === "fast" && !supportsFastMode(session)) {
          await session.q.applyFlagSettings({ fastMode: false })
          session.currentSpeed = "standard"
        }
      } else if (configId === "effort") {
        await session.q.applyFlagSettings({
          effortLevel: value === "default" ? null : value
        } as Parameters<Query["applyFlagSettings"]>[0])
        session.currentEffort = value
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
      await session.q.setPermissionMode(modeId as never)
      session.currentModeId = modeId
      await session.emit({
        kind: "session.updated",
        payload: { modeId },
        subjectId: session.key
      })
    }),
  answerQuestion: (questionId, answer) =>
    adapterPromise("answerQuestion", () => answerClaudeQuestion(session, questionId, answer)),
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
      const subcommand =
        update.status === "paused" ? "pause" : update.status === "active" ? "resume" : undefined
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
  })
})

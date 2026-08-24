import type { Query } from "@anthropic-ai/claude-agent-sdk"
import { isoTimestamp, type SessionGoal } from "@codevisor/api"
import {
  adapterPromise,
  normalizePromptInput,
  type AgentSessionHandle,
  type CancelResult
} from "@codevisor/agent-runtime"
import { claudeContent } from "./attachments.js"
import { emitBackgroundTasks } from "./background-tasks.js"
import { pauseGoalForForcedCancellation, pushGoalCommand } from "./goals.js"
import { deferred } from "./internal.js"
import { effortLevelsFor, metadataFor, supportsFastMode } from "./models.js"
import { answerClaudeQuestion, cancelClaudePendingQuestions } from "./questions.js"
import type { ClaudeSession } from "./session.js"
import {
  ensureObservedTurnStarted,
  ensureTurnStarted,
  failDeferredPrompts,
  finishActiveTurn
} from "./turn-lifecycle.js"

/// Session-handle wiring extracted from makeClaudeProvider as a deps-factory
/// (the makeSkillsOperations pattern): the handleFor body is unchanged, its
/// closed-over provider dependency is injected.
export const makeClaudeSessionHandle = (cancelGraceMs: number) => {
  const handleFor = (session: ClaudeSession): AgentSessionHandle => ({
    cancel: adapterPromise("cancel", async () => {
      if (session.cancelInFlight !== undefined) return session.cancelInFlight
      const cancellation = (async (): Promise<CancelResult> => {
        // Slash commands (notably /goal) can be queued before Claude emits
        // the first observable message. Materialize their user turn so
        // cancellation has a durable lifecycle to settle.
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
        // A held question was cancelled above so it cannot block the SDK from
        // processing the interrupt.
        let timeout: ReturnType<typeof setTimeout> | undefined
        const timedOut = new Promise<"timeout">((resolvePromise) => {
          timeout = setTimeout(() => resolvePromise("timeout"), cancelGraceMs)
        })
        // Acknowledgement is not completion. Keep waiting for the captured
        // terminal event; an interrupt rejection forces recovery immediately.
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

        // The SDK result may have won a same-tick race after the timeout
        // callback fired. It is reusable only while the iterator itself
        // remains alive; a closed stream cannot accept another prompt.
        if (
          outcome !== "interruptFailed" &&
          (outcome === "settled" || !session.turnActive || session.turnId !== capturedTurnId) &&
          !session.streamEnded
        ) {
          await capturedCompletion?.promise
          return { runtimeState: "reusable" }
        }

        // No terminal result arrived. Locally finish and persist the turn
        // before closing the poisoned query; retired sessions ignore late SDK
        // messages, preventing an observed/phantom follow-up turn.
        session.retired = true
        failDeferredPrompts(session, new Error("Claude runtime was retired"))
        if (session.backgroundTasks.size > 0 || session.backgroundShellKeys.size > 0) {
          session.backgroundTasks.clear()
          session.backgroundShellKeys.clear()
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
        // A turn is already running (typically an agent-initiated
        // task-notification follow-up that the dispatcher raced). Binding
        // `pendingPrompt` now would let that turn's terminal event resolve
        // this prompt before it ever ran, and pushing the message now would
        // fold it into the live turn. Defer instead: `finishActiveTurn`
        // dispatches it as its own user-initiated turn.
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
          await session.q.setModel(value)
          session.currentModel = value
          // Effort validity depends on the model; reset rather than carry an
          // unsupported level over.
          if (!effortLevelsFor(session).includes(session.currentEffort)) {
            session.currentEffort = "default"
          }
          // Same for speed: switch fast mode off rather than carry it to a
          // model that doesn't support it.
          if (session.currentSpeed === "fast" && !supportsFastMode(session)) {
            await session.q.applyFlagSettings({ fastMode: false })
            session.currentSpeed = "standard"
          }
        } else if (configId === "effort") {
          // Cast: the CLI accepts "max" but the SDK Settings type doesn't
          // list it yet.
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
        await session.emit({
          kind: "session.updated",
          payload: { modeId },
          subjectId: session.key
        })
      }),
    answerQuestion: (questionId, answer) =>
      adapterPromise("answerQuestion", () => answerClaudeQuestion(session, questionId, answer)),
    // Claude Code's goal mode has no SDK API yet — it's driven by the CLI's
    // `/goal` slash command, which the SDK forwards like any prompt. The
    // snapshots Codevisor emits are therefore client-side bookkeeping (no token
    // accounting); the CLI's own reply narrates the goal state in the chat.
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
  return handleFor
}

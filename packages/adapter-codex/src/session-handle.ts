import { adapterPromise, normalizePromptInput } from "@codevisor/agent-runtime"
import type { AgentSessionHandle, SetGoalUpdate } from "@codevisor/agent-runtime"
import { Effect } from "effect"

import { codexInput } from "./attachments.js"
import { emitGoalCleared, emitGoalSnapshot, sessionGoalFrom } from "./goals.js"
import { isRecord } from "./internal.js"
import {
  CODEX_FAST_TIER,
  CODEX_MODES,
  CODEX_STANDARD_TIER,
  configOptionsFor,
  currentCodexModelFor,
  effectiveSpeed
} from "./models.js"
import { answerCodexQuestion, cancelPendingQuestions } from "./questions.js"
import type { CodexSession } from "./session.js"

export const handleFor = (session: CodexSession): AgentSessionHandle => ({
  cancel: adapterPromise("cancel", async () => {
    const turnId = session.activeTurnId
    if (turnId === undefined) return { runtimeState: "reusable" as const }
    session.interruptRequested = true
    cancelPendingQuestions(session)
    try {
      await session.client.request("turn/interrupt", {
        threadId: session.threadId,
        turnId
      })
    } catch {}
    return { runtimeState: "reusable" as const }
  }),
  close: adapterPromise("close", async () => {
    session.titleGenerator?.close()
    session.pendingPrompt?.resolve({ stopReason: "cancelled" })
    session.pendingPrompt = undefined
    cancelPendingQuestions(session)
    if (session.client.closeAndWait !== undefined) await session.client.closeAndWait()
    else session.client.close()
  }),
  prompt: (input) =>
    adapterPromise("prompt", async () => {
      session.titleGenerator?.rememberPrompt(normalizePromptInput(input).text)
      const pending = new Promise<{ stopReason: string }>((resolve) => {
        session.pendingPrompt = { resolve }
      })
      const mode = CODEX_MODES.find((candidate) => candidate.id === session.currentModeId)
      const speed = effectiveSpeed(session)
      if (mode?.collaboration === "plan") session.collaborationEngaged = true
      const collaborationMode =
        session.currentModel.length > 0 &&
        (mode?.collaboration !== undefined || session.collaborationEngaged)
          ? {
              collaborationMode: {
                mode: mode?.collaboration ?? "default",
                settings: {
                  developer_instructions: null,
                  model: session.currentModel,
                  reasoning_effort: session.currentEffort ?? null
                }
              }
            }
          : {}
      await session.client.request("turn/start", {
        input: codexInput(normalizePromptInput(input), session.skills),
        threadId: session.threadId,
        ...(session.currentModel.length === 0 ? {} : { model: session.currentModel }),
        ...(session.currentEffort === undefined ? {} : { effort: session.currentEffort }),
        ...(session.reasoningSummariesRejected === true ? {} : { summary: "auto" }),
        ...(speed === undefined
          ? {}
          : { serviceTier: speed === "fast" ? CODEX_FAST_TIER : CODEX_STANDARD_TIER }),
        ...(mode === undefined
          ? {}
          : { approvalPolicy: mode.approvalPolicy, sandboxPolicy: mode.sandboxPolicy }),
        ...collaborationMode
      })
      return pending
    }),
  steer: (input) =>
    adapterPromise("steer", async () => {
      const turnId = session.activeTurnId
      if (turnId === undefined || session.interruptRequested) return false
      try {
        await session.client.request("turn/steer", {
          expectedTurnId: turnId,
          input: codexInput(normalizePromptInput(input), session.skills),
          threadId: session.threadId
        })
        return true
      } catch {
        return false
      }
    }),
  setConfigOption: (configId, value) =>
    adapterPromise("setConfigOption", async () => {
      if (configId === "model") {
        session.currentModel = value
        const model = currentCodexModelFor(session)
        if (
          model !== undefined &&
          (session.currentEffort === undefined || !model.efforts.includes(session.currentEffort))
        ) {
          session.currentEffort = model.defaultEffort
        }
        session.currentSpeed = undefined
      } else if (configId === "effort") {
        session.currentEffort = value
      } else if (configId === "speed") {
        session.currentSpeed = value === "fast" ? "fast" : "standard"
      } else {
        throw new Error(`Unknown config option: ${configId}`)
      }
      const configOptions = configOptionsFor(session)
      await session.emit({
        kind: "session.updated",
        payload: { configId, configOptions, value },
        subjectId: session.key
      })
      return configOptions
    }),
  setMode: (modeId) =>
    adapterPromise("setMode", async () => {
      if (!CODEX_MODES.some((mode) => mode.id === modeId)) {
        throw new Error(`Unknown Codex mode: ${modeId}`)
      }
      session.currentModeId = modeId
      await session.emit({
        kind: "session.updated",
        payload: { modeId },
        subjectId: session.key
      })
    }),
  setGoal: (update: SetGoalUpdate) =>
    adapterPromise("setGoal", async () => {
      const response = await session.client.request("thread/goal/set", {
        threadId: session.threadId,
        ...(update.objective === undefined ? {} : { objective: update.objective }),
        ...(update.status === undefined ? {} : { status: update.status }),
        ...("tokenBudget" in update ? { tokenBudget: update.tokenBudget ?? null } : {})
      })
      const goal = sessionGoalFrom(isRecord(response) ? response.goal : undefined)
      if (goal === undefined) {
        throw new Error("codex app-server returned no goal for thread/goal/set")
      }
      await emitGoalSnapshot(session, goal)
      return goal
    }),
  clearGoal: adapterPromise("clearGoal", async () => {
    await session.client.request("thread/goal/clear", { threadId: session.threadId })
    await emitGoalCleared(session)
  }),
  answerQuestion: (questionId, answer) =>
    adapterPromise("answerQuestion", () => answerCodexQuestion(session, questionId, answer)),
  readContext: Effect.sync(() => session.latestContext)
})

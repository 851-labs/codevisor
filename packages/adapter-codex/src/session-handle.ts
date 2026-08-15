import { adapterPromise, normalizePromptInput } from "@codevisor/agent-runtime"
import type { AgentSessionHandle, SetGoalUpdate } from "@codevisor/agent-runtime"
import { codexInput } from "./attachments.js"
import { closeCommandTerminals } from "./command-terminals.js"
import { emitGoalCleared, emitGoalSnapshot, sessionGoalFrom } from "./goals.js"
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

/// Session-handle wiring extracted verbatim from makeCodexProvider: handleFor
/// closes over nothing but its session, so it moves as a plain function.
export const handleFor = (session: CodexSession): AgentSessionHandle => ({
  cancel: adapterPromise("cancel", async () => {
    const turnId = session.activeTurnId
    if (turnId === undefined) return { runtimeState: "reusable" as const }
    session.interruptRequested = true
    // A held question would block the interrupt from ever completing.
    cancelPendingQuestions(session)
    try {
      await session.client.request("turn/interrupt", {
        threadId: session.threadId,
        turnId
      })
    } catch {
      // The turn may already be over.
    }
    return { runtimeState: "reusable" as const }
  }),
  close: adapterPromise("close", async () => {
    // Deliberate closes skip the client's onClose handlers (no spurious
    // session.error), so the in-flight cleanup that handler performed
    // happens here instead.
    session.pendingPrompt?.resolve({ stopReason: "cancelled" })
    session.pendingPrompt = undefined
    cancelPendingQuestions(session)
    closeCommandTerminals(session)
    session.client.close()
  }),
  prompt: (input) =>
    adapterPromise("prompt", async () => {
      const pending = new Promise<{ stopReason: string }>((resolve) => {
        session.pendingPrompt = { resolve }
      })
      const mode = CODEX_MODES.find((candidate) => candidate.id === session.currentModeId)
      const speed = effectiveSpeed(session)
      // Codex's collaboration mode is sticky server-side: once Plan mode is
      // engaged, every later turn must send an explicit collaboration mode or
      // the model stays in Plan. So after any plan turn we keep sending it,
      // and "default" (any non-plan mode) resets codex back out of Plan —
      // mirroring codex CLI's leave-plan-mode action.
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
        input: codexInput(normalizePromptInput(input)),
        threadId: session.threadId,
        ...(session.currentModel.length === 0 ? {} : { model: session.currentModel }),
        ...(session.currentEffort === undefined ? {} : { effort: session.currentEffort }),
        ...(speed === undefined
          ? {}
          : { serviceTier: speed === "fast" ? CODEX_FAST_TIER : CODEX_STANDARD_TIER }),
        ...(mode === undefined
          ? {}
          : { approvalPolicy: mode.approvalPolicy, sandboxPolicy: mode.sandboxPolicy }),
        // EXPERIMENTAL collaboration mode: "plan" makes the model propose a
        // plan (streamed as plan items → plan_document) before implementing;
        // "default" (sent once Plan mode has been left) switches it back to
        // coding. Settings.model is required by the wire shape; settings keys
        // stay snake_case (no camelCase rename upstream).
        ...collaborationMode
      })
      return pending
    }),
  setConfigOption: (configId, value) =>
    adapterPromise("setConfigOption", async () => {
      // Applied as sticky turn/start overrides on subsequent turns.
      if (configId === "model") {
        session.currentModel = value
        const model = currentCodexModelFor(session)
        if (
          model !== undefined &&
          (session.currentEffort === undefined || !model.efforts.includes(session.currentEffort))
        ) {
          session.currentEffort = model.defaultEffort
        }
        // Speed picks don't carry across models — fall back to the new
        // model's default tier.
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
      // Double-option passthrough: an omitted key keeps the current value,
      // an explicit null clears the token budget.
      const response = await session.client.request<{ goal?: unknown }>("thread/goal/set", {
        threadId: session.threadId,
        ...(update.objective === undefined ? {} : { objective: update.objective }),
        ...(update.status === undefined ? {} : { status: update.status }),
        ...("tokenBudget" in update ? { tokenBudget: update.tokenBudget ?? null } : {})
      })
      const goal = sessionGoalFrom(response.goal)
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
    adapterPromise("answerQuestion", () => answerCodexQuestion(session, questionId, answer))
})

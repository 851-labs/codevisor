import * as acp from "@agentclientprotocol/sdk"
import type { SessionGoal } from "@codevisor/api"
import {
  adapterPromise,
  type AgentSessionMetadata,
  type RuntimeEvent,
  type SetGoalUpdate
} from "@codevisor/agent-runtime"
import {
  turnLifecycleEvent,
  type AcpAgentConnection,
  type AcpConnectionExtensionContext,
  type AcpStdioExtensionFactory
} from "@codevisor/adapter-acp"
import { randomUUID } from "node:crypto"
import { Effect } from "effect"
import {
  grokAskUserQuestion,
  grokGoalNotification,
  grokModeState,
  grokPlanApprovalQuestion,
  type GrokAskUserQuestionResponse,
  type GrokPlanApprovalResponse
} from "./grok.js"
import {
  acpConfigOptionIds,
  acpReasoningEffortConfigId,
  acpModelConfigOption,
  acpReasoningEffortConfigOption,
  applyAcpModelSelection,
  applyAcpReasoningEffortSelection,
  extractAcpModelState,
  usesAcpModelSelectionExtension,
  type AcpModelState
} from "./model-selection.js"
import { GrokStreamNormalizer } from "./stream.js"

const withGrokMetadata = (
  metadata: AgentSessionMetadata,
  modelState: AcpModelState | undefined
): AgentSessionMetadata => {
  const configOptions = [...metadata.configOptions]
  if (modelState !== undefined) {
    if (!configOptions.some((option) => option.category === "model")) {
      configOptions.push(acpModelConfigOption(modelState))
    }
    const reasoning = acpReasoningEffortConfigOption(modelState)
    if (
      reasoning !== undefined &&
      !configOptions.some((option) => option.id === acpReasoningEffortConfigId)
    ) {
      configOptions.push(reasoning)
    }
  }
  return {
    ...metadata,
    configOptions,
    modes: metadata.modes ?? grokModeState,
    supportsGoals: true
  }
}

const emitAll = (
  emit: (event: RuntimeEvent) => void,
  events: ReadonlyArray<RuntimeEvent>
): void => {
  for (const event of events) emit(event)
}

const extendGrokConnection = (
  base: AcpAgentConnection,
  context: AcpConnectionExtensionContext,
  emit: (event: RuntimeEvent) => void,
  normalizer: GrokStreamNormalizer,
  goals: Map<string, SessionGoal>
): AcpAgentConnection => {
  const goalTurns = new Map<string, Promise<void>>()

  const runGoalPrompt = (
    sessionId: string,
    prompt: string,
    announceActivity = false
  ): Promise<void> => {
    const turnId = randomUUID()
    emit(turnLifecycleEvent(sessionId, turnId, "started"))
    if (announceActivity) {
      emit({
        kind: "session.output",
        subjectId: sessionId,
        payload: {
          content: { text: "Starting goal", type: "text" },
          sessionUpdate: "agent_thought_chunk"
        }
      })
    }
    const turn = context.connection.agent
      .request(acp.methods.agent.session.prompt, {
        prompt: [{ type: "text", text: prompt }],
        sessionId
      })
      .then(
        (response) => {
          emitAll(emit, normalizer.completeTurn(sessionId))
          emit(turnLifecycleEvent(sessionId, turnId, "ended", response.stopReason))
        },
        (cause) => {
          normalizer.cancelTurn(sessionId)
          emit(turnLifecycleEvent(sessionId, turnId, "ended", "cancelled"))
          throw cause
        }
      )
    goalTurns.set(sessionId, turn)
    void turn
      .catch(() => undefined)
      .finally(() => {
        if (goalTurns.get(sessionId) === turn) goalTurns.delete(sessionId)
      })
    return turn
  }

  const stopGoalTurn = async (sessionId: string): Promise<boolean> => {
    const activeTurn = goalTurns.get(sessionId)
    if (activeTurn === undefined) return false
    context.questions?.cancelQuestions(sessionId)
    normalizer.cancelTurn(sessionId)
    await context.connection.agent.notify(acp.methods.agent.session.cancel, { sessionId })
    await activeTurn.catch(() => undefined)
    return true
  }

  const currentGoalOrThrow = (sessionId: string): SessionGoal => {
    const current = goals.get(sessionId)
    if (current === undefined) throw new Error("No Grok goal is currently set")
    return current
  }

  const setGoal = (sessionId: string, update: SetGoalUpdate) =>
    adapterPromise("setGoal", async () => {
      if (update.objective !== undefined) {
        const objective = update.objective.trim()
        if (objective.length === 0) throw new Error("Goal objective cannot be empty")
        if (update.status !== undefined && update.status !== "active") {
          throw new Error("A new Grok goal must start active")
        }
        if (
          update.tokenBudget !== undefined &&
          update.tokenBudget !== null &&
          (!Number.isSafeInteger(update.tokenBudget) || update.tokenBudget <= 0)
        ) {
          throw new Error("Goal token budget must be a positive integer")
        }
        await stopGoalTurn(sessionId)
        const now = new Date().toISOString()
        const goal: SessionGoal = {
          objective,
          status: "active",
          tokenBudget: update.tokenBudget ?? null,
          tokensUsed: 0,
          timeUsedSeconds: 0,
          createdAt: now,
          updatedAt: now
        }
        goals.set(sessionId, goal)
        const budget =
          update.tokenBudget === undefined || update.tokenBudget === null
            ? ""
            : ` --budget ${update.tokenBudget}`
        runGoalPrompt(sessionId, `/goal ${objective}${budget}`, true)
        return goal
      }

      if (update.tokenBudget !== undefined) {
        throw new Error("Grok can only set a token budget when starting a goal")
      }
      if (update.status === "paused") {
        currentGoalOrThrow(sessionId)
        const cancelledActiveTurn = await stopGoalTurn(sessionId)
        if (!cancelledActiveTurn) await runGoalPrompt(sessionId, "/goal pause")
        const current = currentGoalOrThrow(sessionId)
        const goal = {
          ...current,
          status: "paused" as const,
          updatedAt: new Date().toISOString()
        }
        goals.set(sessionId, goal)
        return goal
      }
      if (update.status === "active") {
        const current = currentGoalOrThrow(sessionId)
        const goal = {
          ...current,
          status: "active" as const,
          updatedAt: new Date().toISOString()
        }
        goals.set(sessionId, goal)
        runGoalPrompt(sessionId, "/goal resume", true)
        return goal
      }
      throw new Error(`Unsupported Grok goal status: ${update.status ?? "unchanged"}`)
    })

  return {
    ...base,
    prompt: (sessionId, input) =>
      base.prompt(sessionId, input).pipe(
        Effect.map((result) => {
          emitAll(emit, normalizer.completeTurn(sessionId))
          return result
        })
      ),
    cancel: (sessionId) =>
      Effect.gen(function* () {
        normalizer.cancelTurn(sessionId)
        return yield* base.cancel(sessionId)
      }),
    setGoal,
    clearGoal: (sessionId) =>
      adapterPromise("clearGoal", async () => {
        await stopGoalTurn(sessionId)
        await runGoalPrompt(sessionId, "/goal clear")
        goals.delete(sessionId)
      })
  }
}

export const makeGrokBuildExtension: AcpStdioExtensionFactory = ({ emit, enqueueQuestion }) => {
  const goals = new Map<string, SessionGoal>()
  const modelStates = new Map<string, AcpModelState>()
  const nativeConfigIds = new Map<string, ReadonlySet<string>>()
  const normalizer = new GrokStreamNormalizer()

  return {
    configureClientApp: (app) => {
      const planApproval = ({ params }: { readonly params: unknown }) => {
        const question = grokPlanApprovalQuestion(params)
        return question === undefined
          ? Promise.resolve({ outcome: "cancelled" as const })
          : enqueueQuestion(question)
      }
      const askUserQuestion = ({ params }: { readonly params: unknown }) => {
        const question = grokAskUserQuestion(params)
        return question === undefined
          ? Promise.resolve({ outcome: "cancelled" as const })
          : enqueueQuestion(question)
      }
      for (const method of ["_x.ai/exit_plan_mode", "x.ai/exit_plan_mode"]) {
        app.onRequest<unknown, GrokPlanApprovalResponse>(method, (params) => params, planApproval)
      }
      for (const method of ["_x.ai/ask_user_question", "x.ai/ask_user_question"]) {
        app.onRequest<unknown, GrokAskUserQuestionResponse>(
          method,
          (params) => params,
          askUserQuestion
        )
      }
      for (const method of ["_x.ai/session_notification", "x.ai/session_notification"]) {
        app.onNotification<unknown>(
          method,
          (params) => params,
          ({ params }) => {
            emitAll(emit, normalizer.mapExtensionNotification(params))
            const mapped = grokGoalNotification(params, (sessionId) => goals.get(sessionId))
            if (mapped === undefined) return
            if (mapped.goal === undefined) goals.delete(mapped.sessionId)
            else goals.set(mapped.sessionId, mapped.goal)
            emit(mapped.event)
          }
        )
      }
      return app
    },
    mapSessionNotification: (notification) => normalizer.mapSessionNotification(notification),
    sdkConnectionCustomization: {
      customizeSessionMetadata: (sessionId, response, metadata) => {
        nativeConfigIds.set(sessionId, acpConfigOptionIds(response))
        const modelState = extractAcpModelState(response)
        if (modelState !== undefined) modelStates.set(sessionId, modelState)
        return withGrokMetadata(metadata, modelState)
      },
      setConfigOption: ({ connection, sessionId, configId, value }) => {
        if (usesAcpModelSelectionExtension(configId, nativeConfigIds.get(sessionId))) {
          return applyAcpModelSelection(connection, modelStates, sessionId, value)
        }
        if (configId === acpReasoningEffortConfigId) {
          return applyAcpReasoningEffortSelection(connection, modelStates, sessionId, value)
        }
        return Promise.resolve(undefined)
      },
      extendConnection: (connection, context) =>
        extendGrokConnection(connection, context, emit, normalizer, goals)
    }
  }
}

import * as acp from "@agentclientprotocol/sdk"
import type { NewSessionResponse } from "@agentclientprotocol/sdk"
import { randomUUID } from "node:crypto"
import type { SessionGoal } from "@codevisor/api"
import {
  adapterPromise,
  clampFailureDetail,
  normalizePromptInput,
  runtimeEffect,
  summarizeProcessFailure,
  type AgentSessionSummary,
  type QuestionAnswer,
  type RuntimeEvent,
  type SetGoalUpdate,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"
import {
  acpConfigSelection,
  normalizeAcpConfigOptions,
  sessionMetadata,
  type AcpSessionMetadataResponse
} from "./config-options.js"
import type { AcpAgentConnection } from "./connection.js"
import type { GrokAskUserQuestionResponse, GrokPlanApprovalResponse } from "./grok.js"
import { isGenericConnectionClose, turnLifecycleEvent } from "./internal.js"
import {
  acpConfigOptionIds,
  acpReasoningEffortConfigId,
  applyAcpModelSelection,
  applyAcpReasoningEffortSelection,
  extractAcpModelState,
  usesAcpModelSelectionExtension,
  type AcpModelState
} from "./model-selection.js"
import { extractPiStartupInfo } from "./pi.js"
import { acpPrompt, type AcpPromptCapabilities } from "./prompt.js"

export interface AcpQuestionControls {
  readonly answerQuestion: (
    sessionId: string,
    questionId: string,
    answer: QuestionAnswer
  ) => Promise<void>
  readonly cancelQuestions: (sessionId: string | undefined) => void
}

export interface AcpGrokControls {
  readonly requestPlanApproval: (params: unknown) => Promise<GrokPlanApprovalResponse>
  readonly askUserQuestion: (params: unknown) => Promise<GrokAskUserQuestionResponse>
  readonly onSessionNotification: (params: unknown) => void
}

export interface AcpAuthControls {
  readonly methods: ReadonlyArray<{
    readonly id: string
    readonly name: string
    readonly description?: string
  }>
  readonly canLogout: boolean
}

/* v8 ignore start -- stdio ACP adapter is exercised by integration/packaging smoke tests. */
export const sdkConnection = (
  connection: acp.ClientConnection,
  stderr: () => string,
  terminate: () => void = () => undefined,
  promptCapabilities: AcpPromptCapabilities = {},
  questions?: AcpQuestionControls,
  auth: AcpAuthControls = { methods: [], canLogout: false },
  piStartupInfoBySession?: Map<string, string>,
  piSessionError?: (sessionId: string) => Promise<string | undefined>,
  harnessId?: string,
  grokGoals: Map<string, SessionGoal> = new Map(),
  onGrokGoalEvent: (event: RuntimeEvent) => void = () => undefined
): AcpAgentConnection => {
  connection.closed.catch(() => undefined)

  // Per-session model list from the ACP model-selection extension, cached so a
  // later `session/set_model` can rebuild the picker with the new current value.
  const modelStates = new Map<string, AcpModelState>()
  // Some adapters (notably pi-acp) expose a native select option whose id is
  // also `model`. That must go through standard ACP set_config_option; the
  // optional session/set_model extension is only for agents without a native
  // model option.
  const nativeConfigIds = new Map<string, ReadonlySet<string>>()
  const grokGoalTurns = new Map<string, Promise<void>>()

  const mcpServers = (toolGateway: ToolGatewayConfig | undefined) =>
    toolGateway === undefined
      ? []
      : [
          {
            type: "http" as const,
            name: toolGateway.name,
            url: toolGateway.url,
            headers: [{ name: "Authorization", value: `Bearer ${toolGateway.bearerToken}` }]
          }
        ]

  const runGrokGoalPrompt = (
    sessionId: string,
    prompt: string,
    announceActivity = false
  ): Promise<void> => {
    const turnId = randomUUID()
    onGrokGoalEvent(turnLifecycleEvent(sessionId, turnId, "started"))
    if (announceActivity) {
      onGrokGoalEvent({
        kind: "session.output",
        subjectId: sessionId,
        payload: {
          content: { text: "Starting goal", type: "text" },
          sessionUpdate: "agent_thought_chunk"
        }
      })
    }
    const turn = connection.agent
      .request(acp.methods.agent.session.prompt, {
        prompt: [{ type: "text", text: prompt }],
        sessionId
      })
      .then(
        (response) => {
          onGrokGoalEvent(turnLifecycleEvent(sessionId, turnId, "ended", response.stopReason))
        },
        (cause) => {
          onGrokGoalEvent(turnLifecycleEvent(sessionId, turnId, "ended", "cancelled"))
          throw cause
        }
      )
    grokGoalTurns.set(sessionId, turn)
    void turn
      .catch(() => undefined)
      .finally(() => {
        if (grokGoalTurns.get(sessionId) === turn) grokGoalTurns.delete(sessionId)
      })
    return turn
  }

  const stopGrokGoalTurn = async (sessionId: string): Promise<boolean> => {
    const activeTurn = grokGoalTurns.get(sessionId)
    if (activeTurn === undefined) return false
    questions?.cancelQuestions(sessionId)
    await connection.agent.notify(acp.methods.agent.session.cancel, { sessionId })
    await activeTurn.catch(() => undefined)
    return true
  }

  const currentGoalOrThrow = (sessionId: string): SessionGoal => {
    const current = grokGoals.get(sessionId)
    if (current === undefined) throw new Error("No Grok goal is currently set")
    return current
  }

  return {
    probeAuth: (cwd) =>
      adapterPromise("probeAuth", async () => {
        try {
          await connection.agent.request(acp.methods.agent.session.new, { cwd, mcpServers: [] })
          return {
            state:
              auth.methods.length === 0 ? ("notRequired" as const) : ("authenticated" as const),
            methods: auth.methods,
            canLogout: auth.canLogout
          }
        } catch (cause) {
          const error = cause as { code?: number; message?: string }
          if (
            error.code === -32000 ||
            error.message?.toLowerCase().includes("authentication required")
          ) {
            return {
              state: "unauthenticated" as const,
              methods: auth.methods,
              canLogout: auth.canLogout
            }
          }
          // `detail` is rendered as the harness row's subtitle during
          // onboarding, so it must stay a single short sentence even when the
          // underlying CLI crashed and its stderr leaked into the message.
          //
          // When a CLI dies on launch the SDK sees EOF on the pipes and rejects
          // pending requests with a bare "ACP connection closed", which races
          // ahead of our own close error and says nothing about the cause. The
          // process's stderr does, so prefer it whenever the message is that
          // generic placeholder.
          const message = cause instanceof Error ? cause.message : String(cause)
          const detail = clampFailureDetail(
            isGenericConnectionClose(message) ? summarizeProcessFailure(stderr(), message) : message
          )
          return {
            state: "error" as const,
            methods: auth.methods,
            canLogout: auth.canLogout,
            ...(detail === undefined ? {} : { detail })
          }
        }
      }),
    authenticate: (methodId) =>
      adapterPromise("authenticate", async () => {
        await connection.agent.request(acp.methods.agent.authenticate, { methodId })
      }),
    logout: adapterPromise("logout", async () => {
      if (!auth.canLogout) throw new Error("ACP agent did not advertise logout support")
      await connection.agent.request(acp.methods.agent.logout, {})
    }),
    ...(questions === undefined
      ? {}
      : {
          answerQuestion: (sessionId: string, questionId: string, answer: QuestionAnswer) =>
            adapterPromise("answerQuestion", () =>
              questions.answerQuestion(sessionId, questionId, answer)
            )
        }),
    listSessions: adapterPromise("listSessions", async () => {
      const sessions: AgentSessionSummary[] = []
      let cursor: string | undefined
      do {
        const response = await connection.agent.request(
          acp.methods.agent.session.list,
          cursor === undefined ? {} : { cursor }
        )
        sessions.push(
          ...response.sessions.map((session) => ({
            cwd: session.cwd,
            sessionId: session.sessionId,
            ...(session.title == null ? {} : { title: session.title }),
            ...(session.updatedAt == null ? {} : { updatedAt: session.updatedAt })
          }))
        )
        const next = response.nextCursor ?? undefined
        if (next === cursor) break
        cursor = next
      } while (cursor !== undefined)
      return sessions
    }),
    createSession: (cwd, toolGateway) =>
      adapterPromise("createSession", async () => {
        const response = (await connection.agent.request(acp.methods.agent.session.new, {
          cwd,
          mcpServers: mcpServers(toolGateway)
        })) as NewSessionResponse
        if (piStartupInfoBySession !== undefined) {
          const startupInfo = extractPiStartupInfo(response)
          if (startupInfo !== undefined) {
            piStartupInfoBySession.set(response.sessionId, startupInfo)
          }
        }
        nativeConfigIds.set(response.sessionId, acpConfigOptionIds(response))
        const modelState = extractAcpModelState(response)
        if (modelState !== undefined) {
          modelStates.set(response.sessionId, modelState)
        }
        return sessionMetadata(response.sessionId, response, modelState, harnessId)
      }),
    loadSession: (sessionId, cwd, toolGateway) =>
      adapterPromise("loadSession", async () => {
        const response = (await connection.agent.request(acp.methods.agent.session.load, {
          cwd,
          mcpServers: mcpServers(toolGateway),
          sessionId
        })) as AcpSessionMetadataResponse
        nativeConfigIds.set(sessionId, acpConfigOptionIds(response))
        const modelState = extractAcpModelState(response)
        if (modelState !== undefined) {
          modelStates.set(sessionId, modelState)
        }
        return sessionMetadata(sessionId, response, modelState, harnessId)
      }),
    prompt: (sessionId, input) =>
      adapterPromise("prompt", async () => {
        const response = await connection.agent.request(acp.methods.agent.session.prompt, {
          prompt: acpPrompt(normalizePromptInput(input), promptCapabilities),
          sessionId
        })
        const stopDetail = await piSessionError?.(sessionId)
        return {
          stopReason: response.stopReason,
          ...(stopDetail === undefined ? {} : { stopDetail })
        }
      }),
    cancel: (sessionId) =>
      adapterPromise("cancel", async () => {
        // Per spec, cancelling a turn resolves its pending permission
        // requests as cancelled before the agent is notified.
        questions?.cancelQuestions(sessionId)
        await connection.agent.notify(acp.methods.agent.session.cancel, { sessionId })
      }),
    setMode: (sessionId, modeId) =>
      adapterPromise("setMode", async () => {
        await connection.agent.request(acp.methods.agent.session.setMode, { modeId, sessionId })
      }),
    setConfigOption: (sessionId, configId, value) =>
      adapterPromise("setConfigOption", async () => {
        // The model picker is the ACP model-selection extension, applied via
        // `session/set_model`. Grok doesn't implement `session/set_config_option`
        // at all, so routing a model change through it would 404.
        if (usesAcpModelSelectionExtension(configId, nativeConfigIds.get(sessionId))) {
          return applyAcpModelSelection(connection, modelStates, sessionId, value)
        }
        if (configId === acpReasoningEffortConfigId) {
          return applyAcpReasoningEffortSelection(connection, modelStates, sessionId, value)
        }
        const selection = acpConfigSelection(harnessId, configId, value)
        const response = await connection.agent.request(acp.methods.agent.session.setConfigOption, {
          configId: selection.configId,
          sessionId,
          value: selection.value
        })
        return normalizeAcpConfigOptions(response.configOptions ?? [], harnessId)
      }),
    ...(harnessId !== "grok-build"
      ? {}
      : {
          setGoal: (sessionId: string, update: SetGoalUpdate) =>
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
                await stopGrokGoalTurn(sessionId)
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
                grokGoals.set(sessionId, goal)
                const budget =
                  update.tokenBudget === undefined || update.tokenBudget === null
                    ? ""
                    : ` --budget ${update.tokenBudget}`
                runGrokGoalPrompt(sessionId, `/goal ${objective}${budget}`, true)
                return goal
              }

              if (update.tokenBudget !== undefined) {
                throw new Error("Grok can only set a token budget when starting a goal")
              }
              if (update.status === "paused") {
                currentGoalOrThrow(sessionId)
                const cancelledActiveTurn = await stopGrokGoalTurn(sessionId)
                if (!cancelledActiveTurn) {
                  await runGrokGoalPrompt(sessionId, "/goal pause")
                }
                const current = currentGoalOrThrow(sessionId)
                const goal = {
                  ...current,
                  status: "paused" as const,
                  updatedAt: new Date().toISOString()
                }
                grokGoals.set(sessionId, goal)
                return goal
              }
              if (update.status === "active") {
                const current = currentGoalOrThrow(sessionId)
                const goal = {
                  ...current,
                  status: "active" as const,
                  updatedAt: new Date().toISOString()
                }
                grokGoals.set(sessionId, goal)
                runGrokGoalPrompt(sessionId, "/goal resume", true)
                return goal
              }
              throw new Error(`Unsupported Grok goal status: ${update.status ?? "unchanged"}`)
            }),
          clearGoal: (sessionId: string) =>
            adapterPromise("clearGoal", async () => {
              await stopGrokGoalTurn(sessionId)
              await runGrokGoalPrompt(sessionId, "/goal clear")
              grokGoals.delete(sessionId)
            })
        }),
    close: runtimeEffect("close", () => {
      connection.close(new Error(summarizeProcessFailure(stderr(), "agent connection closed")))
      terminate()
    })
  }
}
/* v8 ignore stop */

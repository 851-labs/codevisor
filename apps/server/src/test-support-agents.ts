import { harnessCatalog } from "@codevisor/agent-runtime"
import type {
  AgentRuntimeService,
  PromptInput,
  QuestionAnswer,
  RuntimeEvent,
  RuntimeEventSink,
  SetGoalUpdate
} from "@codevisor/agent-runtime"
import type { Harness, SessionConfigOption } from "@codevisor/api"
import { Effect } from "effect"

/// The fake agent runtime the server tests drive: scripted harnesses,
/// sessions, prompts, and the event emitter tests use to simulate agents.

export const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

export const configSelectionsFromTestOptions = (
  options: ReadonlyArray<SessionConfigOption>
): Readonly<Record<string, string>> =>
  Object.fromEntries(options.map((option) => [option.id, option.currentValue]))

export const harnesses: ReadonlyArray<Harness> = [
  {
    id: "codex",
    name: "Codex",
    symbolName: "chevron.left.forwardslash.chevron.right",
    source: "registry",
    launchKind: "npx",
    enabled: true,
    readiness: { state: "ready" },
    installHint: "npm install -g @openai/codex"
  }
]

export const makeAgents = (): AgentRuntimeService & {
  readonly loads: Array<readonly [string, string, string]>
  readonly prompts: Array<readonly [string, string | PromptInput]>
  readonly cancellations: Array<string>
  readonly closes: Array<string>
  readonly modes: Array<readonly [string, string]>
  readonly configs: Array<readonly [string, string, string]>
  readonly configFailures: Array<readonly [string, string, string]>
  readonly goals: Array<readonly [string, SetGoalUpdate]>
  readonly goalClears: Array<string>
  readonly questionAnswers: Array<readonly [string, string, QuestionAnswer]>
  readonly inspections: Array<readonly [string, string]>
  readonly inspectionConfigs: Array<Readonly<Record<string, string>> | undefined>
  readonly creations: Array<readonly [string, string]>
  readonly environmentRefreshes: Array<number>
  readonly sinks: Map<string, RuntimeEventSink>
  readonly emit: (sessionId: string, event: RuntimeEvent) => Promise<void>
} => {
  const loads: Array<readonly [string, string, string]> = []
  const prompts: Array<readonly [string, string | PromptInput]> = []
  const cancellations: Array<string> = []
  const closes: Array<string> = []
  const modes: Array<readonly [string, string]> = []
  const configs: Array<readonly [string, string, string]> = []
  const configFailures: Array<readonly [string, string, string]> = []
  const goals: Array<readonly [string, SetGoalUpdate]> = []
  const goalClears: Array<string> = []
  const questionAnswers: Array<readonly [string, string, QuestionAnswer]> = []
  const inspections: Array<readonly [string, string]> = []
  const inspectionConfigs: Array<Readonly<Record<string, string>> | undefined> = []
  const creations: Array<readonly [string, string]> = []
  const environmentRefreshes: Array<number> = []
  const sinks = new Map<string, RuntimeEventSink>()
  const configOptionsBySession = new Map<string, ReadonlyArray<SessionConfigOption>>()
  const dependencyConfigSessions = new Set<string>()
  const dependencyConfigOptions = (
    model = "model-default",
    reasoning = "low",
    speed = "standard"
  ): ReadonlyArray<SessionConfigOption> => [
    {
      category: "model",
      currentValue: model,
      id: "model",
      name: "Model",
      options: [
        { name: "Default model", value: "model-default" },
        { name: "Saved model", value: "model-saved" }
      ]
    },
    {
      category: "thought_level",
      currentValue: reasoning,
      id: "reasoning",
      name: "Reasoning",
      options:
        model === "model-saved"
          ? [
              { name: "Low", value: "low" },
              { name: "High", value: "high" }
            ]
          : [{ name: "Low", value: "low" }]
    },
    {
      category: "speed",
      currentValue: speed,
      id: "speed",
      name: "Speed",
      options:
        model === "model-saved"
          ? [
              { name: "Standard", value: "standard" },
              { name: "Fast", value: "fast" }
            ]
          : [{ name: "Standard", value: "standard" }]
    },
    {
      category: "tone",
      currentValue: "brief",
      id: "tone",
      name: "Tone",
      options: [
        {
          group: "response-style",
          name: "Response style",
          options: [
            { name: "Brief", value: "brief" },
            { name: "Detailed", value: "detailed" }
          ]
        }
      ]
    }
  ]
  const emit = async (sessionId: string, event: RuntimeEvent): Promise<void> => {
    await sinks.get(sessionId)?.(event)
  }
  /// Turns that run until `cancel` ("prompt until cancelled"): lets tests
  /// exercise interrupt paths deterministically instead of racing a timer.
  const cancellable = new Map<string, () => void>()
  return {
    loads,
    prompts,
    cancellations,
    closes,
    modes,
    configs,
    configFailures,
    goals,
    goalClears,
    questionAnswers,
    inspections,
    inspectionConfigs,
    creations,
    environmentRefreshes,
    sinks,
    emit,
    catalog: harnessCatalog,
    setExtraHarnesses: () => {},
    discoverHarnesses: Effect.succeed(harnesses),
    refreshEnvironment: Effect.sync(() => {
      environmentRefreshes.push(environmentRefreshes.length + 1)
    }),
    listAgentSessions: (harnessId) =>
      Effect.succeed(
        harnessId === "codex"
          ? [{ sessionId: "native-1", cwd: "/repo/native", title: "Old codex chat" }]
          : []
      ),
    readHarnessUsageLimits: (harnessId) =>
      Effect.succeed({
        fetchedAt: "2026-01-01T00:00:00.000Z",
        harnessId,
        state: "unavailable" as const,
        windows: []
      }),
    createAgentSession: (harnessId, cwd, sink) =>
      Effect.promise(
        () =>
          new Promise<string>((resolve) => {
            creations.push([harnessId, cwd])
            const delayMs = cwd.includes("pending-create") ? 100 : 5
            setTimeout(() => {
              const sessionId = `agent-${harnessId}-${cwd.split("/").at(-1) ?? "root"}`
              sinks.set(sessionId, sink)
              resolve(sessionId)
            }, delayMs)
          })
      ),
    inspectHarness: (harnessId, cwd, _account, configSelections) =>
      Effect.sync(() => {
        inspections.push([harnessId, cwd])
        inspectionConfigs.push(configSelections)
        if (cwd.includes("capability-fail")) {
          throw new Error("capability probe failed")
        }
        if (cwd.includes("no-modes")) {
          return {
            sessionId: `inspect-${harnessId}`,
            configOptions: []
          }
        }
        const model = configSelections?.model ?? "gpt-5"
        return {
          sessionId: `inspect-${harnessId}`,
          supportsGoals: true,
          modes: {
            currentModeId: "default",
            availableModes: [{ id: "default", name: "Default" }]
          },
          configOptions: [
            {
              id: "model",
              name: "Model",
              category: "model",
              currentValue: model,
              options: [{ value: "gpt-5", name: "GPT-5" }]
            },
            {
              id: "reasoning",
              name: "Reasoning",
              category: "thought_level",
              currentValue: model === "gpt-next" ? "high" : "medium",
              options:
                model === "gpt-next"
                  ? [{ value: "high", name: "High" }]
                  : [{ value: "medium", name: "Medium" }]
            }
          ]
        }
      }),
    loadAgentSession: (harnessId, agentSessionId, cwd, sink) =>
      Effect.sync(() => {
        loads.push([harnessId, agentSessionId, cwd])
        sinks.set(agentSessionId, sink)
        if (cwd.includes("session-config")) {
          dependencyConfigSessions.add(agentSessionId)
          const configOptions = dependencyConfigOptions()
          configOptionsBySession.set(agentSessionId, configOptions)
          return { configOptions, sessionId: agentSessionId }
        }
        const configOptions: ReadonlyArray<SessionConfigOption> = [
          {
            category: "model",
            currentValue: "gpt-current",
            id: "model",
            name: "Model",
            options: [
              { name: "GPT Current", value: "gpt-current" },
              { name: "GPT New", value: "gpt-new" }
            ]
          }
        ]
        configOptionsBySession.set(agentSessionId, configOptions)
        return {
          configOptions,
          sessionId: agentSessionId
        }
      }),
    prompt: (sessionId, input) =>
      Effect.promise(async () => {
        const text = typeof input === "string" ? input : input.text
        prompts.push([sessionId, input])
        if (text === "slow prompt") {
          await new Promise((resolve) => setTimeout(resolve, 250))
        }
        if (text === "prompt until cancelled") {
          const turnId = `turn-${prompts.length}`
          await emit(sessionId, {
            kind: "session.updated",
            subjectId: sessionId,
            payload: { initiatedBy: "user", turnId, turnState: "started" }
          })
          await new Promise<void>((resolve) => cancellable.set(sessionId, resolve))
          await emit(sessionId, {
            kind: "session.updated",
            subjectId: sessionId,
            payload: { initiatedBy: "user", stopReason: "cancelled", turnId, turnState: "ended" }
          })
          return { stopReason: "cancelled" }
        }
        if (text === "prompt fails") {
          throw new Error("prompt failed")
        }
        if (text === "token expired") {
          throw new Error("authentication token expired")
        }
        const turnId = `turn-${prompts.length}`
        await emit(sessionId, {
          kind: "session.updated",
          subjectId: sessionId,
          payload: { initiatedBy: "user", turnId, turnState: "started" }
        })
        const events =
          text === "raw chunks" || text === "returned events"
            ? [
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    content: { text, type: "text" },
                    messageId: "user-raw",
                    sessionUpdate: "user_message_chunk"
                  }
                },
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    content: { text: "raw user without id", type: "text" },
                    sessionUpdate: "user_message_chunk"
                  }
                },
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    content: { text: "Raw answer", type: "text" },
                    messageId: "assistant-raw",
                    sessionUpdate: "agent_message_chunk"
                  }
                },
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    content: { text: "Raw answer without id", type: "text" },
                    sessionUpdate: "agent_message_chunk"
                  }
                },
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    content: { text: "thought", type: "text" },
                    messageId: "thought-raw",
                    sessionUpdate: "agent_thought_chunk"
                  }
                },
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    content: { type: "image" },
                    messageId: "image-raw",
                    sessionUpdate: "agent_message_chunk"
                  }
                },
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    role: "assistant",
                    text: 42
                  }
                },
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    role: "assistant",
                    text: "bad message id",
                    messageId: 42
                  }
                }
              ]
            : [
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: { role: "assistant", text: `Echo: ${text}` }
                }
              ]
        for (const event of events) {
          await emit(sessionId, event)
        }
        await emit(sessionId, {
          kind: "session.updated",
          subjectId: sessionId,
          payload: { initiatedBy: "user", stopReason: "end_turn", turnId, turnState: "ended" }
        })
        return { stopReason: "end_turn" }
      }),
    cancel: (sessionId) =>
      Effect.sync(() => {
        cancellations.push(sessionId)
        cancellable.get(sessionId)?.()
        cancellable.delete(sessionId)
        return { runtimeState: "reusable" as const }
      }),
    loadedAgentSessionIds: () => [...sinks.keys()],
    closeAgentSession: (sessionId) =>
      Effect.sync(() => {
        closes.push(sessionId)
        sinks.delete(sessionId)
      }),
    setMode: (sessionId, modeId) =>
      Effect.promise(async () => {
        modes.push([sessionId, modeId])
        await emit(sessionId, {
          kind: "session.updated",
          subjectId: sessionId,
          payload: { modeId }
        })
      }),
    setConfigOption: (sessionId, configId, value) =>
      Effect.promise(async () => {
        configs.push([sessionId, configId, value])
        const failureIndex = configFailures.findIndex(
          ([wantedSession, wantedConfig, wantedValue]) =>
            wantedSession === sessionId && wantedConfig === configId && wantedValue === value
        )
        if (failureIndex >= 0) {
          configFailures.splice(failureIndex, 1)
          throw new Error(`Transient config failure: ${configId}`)
        }
        const current = configOptionsBySession.get(sessionId) ?? []
        let configOptions: ReadonlyArray<SessionConfigOption>
        if (dependencyConfigSessions.has(sessionId) && configId === "model") {
          configOptions = dependencyConfigOptions(value)
        } else {
          const option = current.find((candidate) => candidate.id === configId)
          if (dependencyConfigSessions.has(sessionId)) {
            const values =
              option?.options.flatMap((entry) =>
                "value" in entry ? [entry.value] : entry.options.map((nested) => nested.value)
              ) ?? []
            if (!values.includes(value)) {
              throw new Error(`Unsupported ${configId}: ${value}`)
            }
          }
          configOptions = current.map((candidate) =>
            candidate.id === configId ? { ...candidate, currentValue: value } : candidate
          )
        }
        configOptionsBySession.set(sessionId, configOptions)
        await emit(sessionId, {
          kind: "session.updated",
          subjectId: sessionId,
          payload: { configId, configOptions, value }
        })
        return configOptions
      }),
    setGoal: (sessionId, update) =>
      Effect.promise(async () => {
        if (update.objective === "goal fails") {
          throw new Error("Goals are not supported by this harness")
        }
        goals.push([sessionId, update])
        const goal = {
          createdAt: "2026-07-05T00:00:00.000Z",
          objective: update.objective ?? "existing objective",
          status: update.status ?? ("active" as const),
          timeUsedSeconds: 0,
          tokenBudget: update.tokenBudget ?? null,
          tokensUsed: 0,
          updatedAt: "2026-07-05T00:00:00.000Z"
        }
        await emit(sessionId, {
          kind: "session.updated",
          subjectId: sessionId,
          payload: { goal }
        })
        return goal
      }),
    clearGoal: (sessionId) =>
      Effect.promise(async () => {
        goalClears.push(sessionId)
        await emit(sessionId, {
          kind: "session.updated",
          subjectId: sessionId,
          payload: { goalCleared: true }
        })
      }),
    probeHarnessAuth: () => Effect.succeed({ state: "notRequired", methods: [], canLogout: false }),
    authenticateHarness: () => Effect.void,
    logoutHarness: () => Effect.void,
    answerQuestion: (sessionId, questionId, answer) =>
      Effect.promise(async () => {
        if (questionId === "stale-question") {
          throw new Error("No pending question: stale-question")
        }
        questionAnswers.push([sessionId, questionId, answer])
        await emit(sessionId, {
          kind: "session.output",
          subjectId: sessionId,
          payload: {
            outcome: answer.outcome,
            questionId,
            questions: [],
            sessionUpdate: "question_resolved"
          }
        })
      })
  }
}

import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import {
  toEventEnvelope,
  type QuestionAnswer,
  type RuntimeEmit,
  type RuntimeEvent,
  type SetGoalUpdate
} from "@codevisor/agent-runtime"
import { acpProtocolVersion, type AcpConnector } from "./index.js"
import {
  conversationEvent,
  FakeConnection,
  makeAcpAgentRuntime,
  makeConnector,
  run
} from "./test-support.js"

describe("@codevisor/agent-runtime", () => {
  it("streams turn lifecycle and session output through the persistent sink", async () => {
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => ["gemini", "npx"].includes(name),
      locateExecutable: (name) => `/bin/${name}`
    })
    const events: Array<RuntimeEvent> = []
    const sessionId = await run(
      runtime.createAgentSession("gemini", "/tmp/project", (event) => {
        events.push(event)
      })
    )

    const result = await run(runtime.prompt(sessionId, "hello"))
    expect(result.stopReason).toBe("end_turn")
    expect(events).toHaveLength(4)
    expect(events[0]).toMatchObject({
      kind: "session.updated",
      subjectId: sessionId,
      payload: { turnState: "started", initiatedBy: "user" }
    })
    expect(events[1]).toEqual(conversationEvent(sessionId, "user", "hello"))
    expect(events[2]).toEqual(conversationEvent(sessionId, "assistant", "Echo: hello"))
    expect(events[3]).toMatchObject({
      kind: "session.updated",
      payload: { turnState: "ended", initiatedBy: "user", stopReason: "end_turn" }
    })
    const startedTurnId = (events[0]?.payload as { turnId?: string }).turnId
    expect(startedTurnId).toBeTruthy()
    expect((events[3]?.payload as { turnId?: string }).turnId).toBe(startedTurnId)

    expect(connector.connections[0]?.prompts).toEqual([[sessionId, "hello"]])

    await expect(run(runtime.prompt("missing", "hello"))).rejects.toThrow(
      "Agent session is not loaded"
    )
  })

  it("preserves retryable terminal metadata from an extended ACP connection", async () => {
    class RetryableConnection extends FakeConnection {
      override prompt(_sessionId: string, _input: Parameters<FakeConnection["prompt"]>[1]) {
        return Effect.succeed({
          retryable: true,
          stopDetail: "Cursor is temporarily unavailable.",
          stopReason: "end_turn"
        })
      }
    }
    const connector: AcpConnector = {
      connect: (request, emit) => Effect.succeed(new RetryableConnection(request, emit))
    }
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => name === "gemini",
      locateExecutable: (name) => `/bin/${name}`
    })
    const events: Array<RuntimeEvent> = []
    const sessionId = await run(
      runtime.createAgentSession("gemini", "/tmp/project", (event) => {
        events.push(event)
      })
    )

    await run(runtime.prompt(sessionId, "hello"))

    expect(events.at(-1)).toMatchObject({
      kind: "session.updated",
      payload: {
        retryable: true,
        stopDetail: "Cursor is temporarily unavailable.",
        stopReason: "end_turn",
        turnState: "ended"
      },
      subjectId: sessionId
    })
  })

  it("delivers events that arrive with no prompt in flight", async () => {
    // Regression test for the dropped-background-events bug: the sink used to
    // exist only for the duration of a prompt request.
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => ["gemini", "npx"].includes(name),
      locateExecutable: (name) => `/bin/${name}`
    })
    const events: Array<RuntimeEvent> = []
    const sessionId = await run(
      runtime.createAgentSession("gemini", "/tmp/project", (event) => {
        events.push(event)
      })
    )
    await run(runtime.prompt(sessionId, "kick off background work"))
    events.length = 0

    const connection = connector.connections[0]
    if (connection === undefined) {
      throw new Error("expected a fake connection")
    }
    await connection.emit(conversationEvent(sessionId, "assistant", "background task finished"))

    expect(events).toEqual([conversationEvent(sessionId, "assistant", "background task finished")])
  })

  it("keeps per-session event order through the serial sink chain", async () => {
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => ["gemini", "npx"].includes(name),
      locateExecutable: (name) => `/bin/${name}`
    })
    const seen: Array<string> = []
    const sessionId = await run(
      runtime.createAgentSession("gemini", "/tmp/project", async (event) => {
        // A slow async sink must not reorder events.
        await new Promise((resolve) => setTimeout(resolve, 1))
        seen.push((event.payload as { text?: string }).text ?? "lifecycle")
      })
    )
    const connection = connector.connections[0]
    if (connection === undefined) {
      throw new Error("expected a fake connection")
    }
    void connection.emit(conversationEvent(sessionId, "assistant", "one"))
    void connection.emit(conversationEvent(sessionId, "assistant", "two"))
    await connection.emit(conversationEvent(sessionId, "assistant", "three"))

    expect(seen).toEqual(["one", "two", "three"])
  })

  it("emits mode and config updates through the sink", async () => {
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => ["gemini", "npx"].includes(name),
      locateExecutable: (name) => `/bin/${name}`
    })
    const events: Array<RuntimeEvent> = []
    const sessionId = await run(
      runtime.createAgentSession("gemini", "/tmp/project", (event) => {
        events.push(event)
      })
    )

    await run(runtime.cancel(sessionId))
    await run(runtime.setMode(sessionId, "plan"))
    const configOptions = await run(runtime.setConfigOption(sessionId, "model", "gpt-5"))

    expect(connector.connections[0]?.cancellations).toEqual([sessionId])
    expect(events).toHaveLength(3)
    expect(events[0]).toMatchObject({
      kind: "session.updated",
      payload: { turnState: "ended", stopReason: "cancelled" }
    })
    expect(events[1]).toMatchObject({
      kind: "session.updated",
      payload: { modeId: "plan" }
    })
    expect(events[2]).toMatchObject({
      kind: "session.updated",
      payload: { configId: "model", value: "gpt-5" }
    })
    expect(configOptions).toEqual([{ currentValue: "gpt-5", id: "model" }])
  })

  it("fails goal calls on harnesses without goal support", async () => {
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => ["gemini", "npx"].includes(name),
      locateExecutable: (name) => `/bin/${name}`
    })
    const sessionId = await run(
      runtime.createAgentSession("gemini", "/tmp/project", () => undefined)
    )
    // The ACP handle exposes no goal surface, so the runtime rejects cleanly.
    await expect(run(runtime.setGoal(sessionId, { objective: "x" }))).rejects.toThrow(
      "Goals are not supported by this harness"
    )
    await expect(run(runtime.clearGoal(sessionId))).rejects.toThrow(
      "Goals are not supported by this harness"
    )
    await expect(
      run(runtime.answerQuestion(sessionId, "q-1", { outcome: "cancelled" }))
    ).rejects.toThrow("Questions are not supported by this harness")
  })

  it("preserves optional question and goal methods through the generic ACP provider", async () => {
    const answered: Array<readonly [string, string, QuestionAnswer]> = []
    const goalUpdates: Array<readonly [string, SetGoalUpdate]> = []
    const cleared: Array<string> = []
    const goal = {
      createdAt: "2026-08-20T00:00:00.000Z",
      objective: "finish the adapter",
      status: "active" as const,
      timeUsedSeconds: 0,
      tokenBudget: null,
      tokensUsed: 0,
      updatedAt: "2026-08-20T00:00:00.000Z"
    }
    class InteractiveConnection extends FakeConnection {
      answerQuestion(sessionId: string, questionId: string, answer: QuestionAnswer) {
        return Effect.sync(() => {
          answered.push([sessionId, questionId, answer])
        })
      }

      setGoal(sessionId: string, update: SetGoalUpdate) {
        return Effect.sync(() => {
          goalUpdates.push([sessionId, update])
          return goal
        })
      }

      clearGoal(sessionId: string) {
        return Effect.sync(() => {
          cleared.push(sessionId)
        })
      }
    }
    const connector: AcpConnector = {
      connect: (request, emit) => Effect.succeed(new InteractiveConnection(request, emit))
    }
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => name === "gemini",
      locateExecutable: (name) => `/bin/${name}`
    })
    const sessionId = await run(
      runtime.createAgentSession("gemini", "/tmp/project", () => undefined)
    )
    const answer = { answers: { choice: { answers: ["A"] } }, outcome: "answered" as const }

    await expect(run(runtime.setGoal(sessionId, { status: "paused" }))).resolves.toEqual(goal)
    await expect(
      run(runtime.answerQuestion(sessionId, "question-1", answer))
    ).resolves.toBeUndefined()
    await expect(run(runtime.clearGoal(sessionId))).resolves.toBeUndefined()

    expect(goalUpdates).toEqual([[sessionId, { status: "paused" }]])
    expect(answered).toEqual([[sessionId, "question-1", answer]])
    expect(cleared).toEqual([sessionId])
  })

  it("delegates goal calls to handles that support them", async () => {
    const goalCalls: Array<unknown> = []
    let clearCount = 0
    const goal = {
      createdAt: "2026-07-05T00:00:00.000Z",
      objective: "finish the migration",
      status: "active" as const,
      timeUsedSeconds: 0,
      tokenBudget: null,
      tokensUsed: 0,
      updatedAt: "2026-07-05T00:00:00.000Z"
    }
    const answered: Array<readonly [string, unknown]> = []
    const custom = {
      createSession: () =>
        Effect.sync(() => ({
          handle: {
            answerQuestion: (questionId: string, answer: unknown) =>
              Effect.sync(() => {
                answered.push([questionId, answer])
              }),
            cancel: Effect.void,
            clearGoal: Effect.sync(() => {
              clearCount += 1
            }),
            close: Effect.void,
            prompt: () => Effect.succeed({ stopReason: "end_turn" }),
            setConfigOption: () => Effect.succeed([]),
            setGoal: (update: unknown) =>
              Effect.sync(() => {
                goalCalls.push(update)
                return goal
              }),
            setMode: () => Effect.void
          },
          metadata: { configOptions: [], sessionId: "goal-1", supportsGoals: true }
        })),
      id: "codex" as const,
      loadSession: () => Effect.die("unused"),
      readiness: () => ({ state: "ready" }) as const
    }
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: () => true,
      locateExecutable: (name) => `/bin/${name}`,
      providers: { codex: custom as never }
    })
    const sessionId = await run(
      runtime.createAgentSession("codex", "/tmp/project", () => undefined)
    )
    const result = await run(runtime.setGoal(sessionId, { status: "paused" }))
    expect(result).toEqual(goal)
    expect(goalCalls).toEqual([{ status: "paused" }])
    await run(runtime.clearGoal(sessionId))
    expect(clearCount).toBe(1)
    await run(
      runtime.answerQuestion(sessionId, "q-7", {
        answers: { q: { answers: ["A"] } },
        outcome: "answered"
      })
    )
    expect(answered).toEqual([["q-7", { answers: { q: { answers: ["A"] } }, outcome: "answered" }]])
  })

  it("registers custom providers and drops events for unknown sessions", async () => {
    const events: Array<RuntimeEvent> = []
    let capturedEmit: RuntimeEmit | undefined
    const handle = {
      cancel: Effect.void,
      close: Effect.void,
      prompt: () => Effect.succeed({ stopReason: "end_turn" }),
      setConfigOption: () => Effect.succeed([]),
      setMode: () => Effect.void
    }
    const custom = {
      createSession: (_definition: unknown, _cwd: unknown, emit: RuntimeEmit) =>
        Effect.sync(() => {
          capturedEmit = emit
          return {
            handle,
            metadata: {
              configOptions: [],
              modes: {
                availableModes: [
                  { id: "default", name: "Default" },
                  { id: "plan", name: "Plan" }
                ],
                currentModeId: "default"
              },
              sessionId: "custom-1"
            }
          }
        }),
      id: "claude" as const,
      loadSession: (_definition: unknown, agentSessionId: string) =>
        Effect.succeed({ handle, sessionId: agentSessionId }),
      readiness: () => ({ state: "ready" }) as const
    }
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: () => true,
      locateExecutable: (name) => `/bin/${name}`,
      providers: { claude: custom as never }
    })
    const sessionId = await run(
      runtime.createAgentSession("claude-code", "/tmp/project", (event) => {
        events.push(event)
      })
    )
    expect(sessionId).toBe("custom-1")
    // Events for sessions the runtime doesn't know are dropped, not crashed on.
    await capturedEmit?.({ kind: "session.output", payload: {}, subjectId: "unknown-session" })
    await capturedEmit?.({ kind: "session.output", payload: { ok: true }, subjectId: "custom-1" })
    await capturedEmit?.({ kind: "session.output", payload: "raw", subjectId: "custom-1" })
    await capturedEmit?.({ kind: "session.output", payload: null, subjectId: "custom-1" })
    await capturedEmit?.({
      kind: "session.updated",
      payload: { modeId: 42 },
      subjectId: "custom-1"
    })
    await capturedEmit?.({
      kind: "session.output",
      payload: { currentModeId: 42, sessionUpdate: "current_mode_update" },
      subjectId: "custom-1"
    })
    await capturedEmit?.({
      kind: "session.output",
      payload: { currentModeId: "default", sessionUpdate: "current_mode_update" },
      subjectId: "custom-1"
    })
    await capturedEmit?.({
      kind: "session.updated",
      payload: { modeId: "plan" },
      subjectId: "custom-1"
    })
    const reloaded = await run(
      runtime.loadAgentSession("claude-code", "custom-1", "/tmp/project", () => undefined)
    )
    expect(reloaded.modes?.currentModeId).toBe("plan")
    await expect(
      run(runtime.loadAgentSession("claude-code", "custom-2", "/tmp/project", () => undefined))
    ).resolves.toEqual({ configOptions: [], sessionId: "custom-2" })
    expect(events).toEqual([
      { kind: "session.output", payload: { ok: true }, subjectId: "custom-1" },
      { kind: "session.output", payload: "raw", subjectId: "custom-1" },
      { kind: "session.output", payload: null, subjectId: "custom-1" },
      { kind: "session.updated", payload: { modeId: 42 }, subjectId: "custom-1" },
      {
        kind: "session.output",
        payload: { currentModeId: 42, sessionUpdate: "current_mode_update" },
        subjectId: "custom-1"
      },
      {
        kind: "session.output",
        payload: { currentModeId: "default", sessionUpdate: "current_mode_update" },
        subjectId: "custom-1"
      },
      { kind: "session.updated", payload: { modeId: "plan" }, subjectId: "custom-1" }
    ])
  })

  it("materializes runtime events as envelopes", () => {
    expect(
      toEventEnvelope("server", 7, {
        kind: "session.output",
        subjectId: "session-1",
        payload: { text: "chunk" }
      })
    ).toMatchObject({
      id: 7,
      serverId: "server",
      kind: "session.output",
      subjectId: "session-1",
      payload: { text: "chunk" }
    })
    expect(acpProtocolVersion).toBe(1)
  })
})

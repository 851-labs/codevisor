import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import {
  AgentRuntime,
  acpProtocolVersion,
  makeAgentRuntime,
  runtimeEventFromNotification,
  toEventEnvelope,
  type AcpAgentConnection,
  type AcpConnector,
  type AcpHarnessLaunchRequest,
  type AgentRuntimeError,
  type RuntimeEmit,
  type RuntimeEvent
} from "./index.js"

const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

class FakeConnection implements AcpAgentConnection {
  readonly created: Array<string> = []
  readonly loaded: Array<readonly [string, string]> = []
  readonly prompts: Array<readonly [string, string]> = []
  readonly cancellations: Array<string> = []
  readonly modes: Array<readonly [string, string]> = []
  readonly configs: Array<readonly [string, string, string]> = []
  closeCount = 0
  failClose = false

  constructor(
    readonly request: AcpHarnessLaunchRequest,
    readonly emit: RuntimeEmit
  ) {
    this.failClose = request.cwd.includes("fail-close")
  }

  createSession(cwd: string): Effect.Effect<
    {
      readonly sessionId: string
      readonly configOptions: []
    },
    AgentRuntimeError
  > {
    return Effect.sync(() => {
      this.created.push(cwd)
      return { configOptions: [], sessionId: `agent-${this.request.harnessId}-1` }
    })
  }

  loadSession(sessionId: string, cwd: string): Effect.Effect<string, AgentRuntimeError> {
    return Effect.sync(() => {
      this.loaded.push([sessionId, cwd])
      return sessionId
    })
  }

  prompt(
    sessionId: string,
    text: string
  ): Effect.Effect<{ readonly stopReason: string }, AgentRuntimeError> {
    return Effect.promise(async () => {
      this.prompts.push([sessionId, text])
      await this.emit(conversationEvent(sessionId, "user", text))
      await this.emit(conversationEvent(sessionId, "assistant", `Echo: ${text}`))
      return { stopReason: "end_turn" }
    })
  }

  cancel(sessionId: string): Effect.Effect<void, AgentRuntimeError> {
    return Effect.sync(() => {
      this.cancellations.push(sessionId)
    })
  }

  setMode(sessionId: string, modeId: string): Effect.Effect<void, AgentRuntimeError> {
    return Effect.sync(() => {
      this.modes.push([sessionId, modeId])
    })
  }

  setConfigOption(
    sessionId: string,
    configId: string,
    value: string
  ): Effect.Effect<unknown, AgentRuntimeError> {
    return Effect.sync(() => {
      this.configs.push([sessionId, configId, value])
      return [{ currentValue: value, id: configId }]
    })
  }

  readonly close: Effect.Effect<void, AgentRuntimeError> = Effect.sync(() => {
    this.closeCount += 1
    if (this.failClose) {
      throw new Error("close failed")
    }
  })
}

const makeConnector = (): AcpConnector & {
  readonly connections: ReadonlyArray<FakeConnection>
  readonly requests: ReadonlyArray<AcpHarnessLaunchRequest>
} => {
  const connections: Array<FakeConnection> = []
  const requests: Array<AcpHarnessLaunchRequest> = []
  return {
    connections,
    requests,
    connect: (request, emit) =>
      Effect.sync(() => {
        requests.push(request)
        const connection = new FakeConnection(request, emit)
        connections.push(connection)
        return connection
      })
  }
}

const conversationEvent = (
  sessionId: string,
  role: "user" | "assistant",
  text: string
): RuntimeEvent => ({
  kind: "session.output",
  payload: { role, text },
  subjectId: sessionId
})

describe("@herdman/agent-runtime", () => {
  it("discovers ready, missing-runner, and unavailable harnesses", async () => {
    const runtime = makeAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: (name) => ["gemini", "opencode", "codex"].includes(name)
    })

    const harnesses = await run(runtime.discoverHarnesses)
    expect(harnesses.find((harness) => harness.id === "gemini")?.readiness).toEqual({
      state: "unavailable",
      detail: "Requires npx"
    })
    // Native providers need only their binary — no npx.
    expect(harnesses.find((harness) => harness.id === "codex")?.readiness).toEqual({
      state: "ready"
    })
    expect(harnesses.find((harness) => harness.id === "opencode")?.readiness).toEqual({
      state: "ready"
    })
    expect(harnesses.find((harness) => harness.id === "claude-code")?.readiness.detail).toBe(
      "CLI not found on PATH"
    )
    expect(harnesses.find((harness) => harness.id === "factory-droid")?.launchKind).toBe("npx")
    // Cursor is pulled until cursor-agent's ACP mode stabilizes upstream.
    expect(harnesses.find((harness) => harness.id === "cursor")?.readiness).toMatchObject({
      state: "unavailable",
      detail: expect.stringContaining("Temporarily disabled")
    })
  })

  it("refuses sessions for disabled harnesses", async () => {
    const runtime = makeAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: () => true,
      locateExecutable: (name) => `/bin/${name}`
    })
    await expect(
      run(runtime.createAgentSession("cursor", "/tmp/project", () => undefined))
    ).rejects.toThrow("Cursor is unavailable")
  })

  it("creates and loads agent sessions through the connector", async () => {
    const connector = makeConnector()
    const runtime = makeAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => ["gemini", "npx"].includes(name),
      locateExecutable: (name) => `/bin/${name}`
    })
    const sink = (): void => undefined

    const created = await run(runtime.createAgentSession("gemini", "/tmp/project", sink))
    const inspected = await run(runtime.inspectHarness("gemini", "/tmp/project"))
    const inspectedWithCloseFailure = await run(runtime.inspectHarness("gemini", "/tmp/fail-close"))
    const loaded = await run(
      runtime.loadAgentSession("gemini", "agent-existing", "/tmp/project", sink)
    )
    const loadedAgain = await run(
      runtime.loadAgentSession("gemini", "agent-existing", "/tmp/project", sink)
    )
    const previousLoadedConnection = connector.connections[3]
    if (previousLoadedConnection === undefined) {
      throw new Error("expected a loaded fake connection")
    }
    previousLoadedConnection.failClose = true
    const reloadedElsewhere = await run(
      runtime.loadAgentSession("gemini", "agent-existing", "/tmp/other", sink)
    )
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(created).toBe("agent-gemini-1")
    expect(inspected).toEqual({ configOptions: [], sessionId: "agent-gemini-1" })
    expect(inspectedWithCloseFailure).toEqual({ configOptions: [], sessionId: "agent-gemini-1" })
    expect(loaded).toBe("agent-existing")
    expect(loadedAgain).toBe("agent-existing")
    expect(reloadedElsewhere).toBe("agent-existing")
    expect(connector.requests).toHaveLength(5)
    expect(connector.requests[0]).toMatchObject({
      args: ["-y", "@google/gemini-cli@0.49.0", "--acp"],
      command: "/bin/npx",
      cwd: "/tmp/project",
      harnessId: "gemini"
    })
    expect(connector.connections[0]?.created).toEqual(["/tmp/project"])
    expect(connector.connections[3]?.loaded).toEqual([["agent-existing", "/tmp/project"]])
    expect(previousLoadedConnection.closeCount).toBe(1)
    expect(connector.connections[4]?.loaded).toEqual([["agent-existing", "/tmp/other"]])
  })

  it("falls back to executable names when PATH lookup is delegated", async () => {
    const connector = makeConnector()
    const runtime = makeAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => ["gemini", "npx", "opencode"].includes(name),
      locateExecutable: () => undefined
    })
    const sink = (): void => undefined

    await run(runtime.createAgentSession("gemini", "/tmp/project", sink))
    await run(runtime.createAgentSession("opencode", "/tmp/project", sink))

    expect(connector.requests.map((request) => request.command)).toEqual(["npx", "opencode"])
    expect(connector.requests[1]?.args).toEqual(["acp"])
  })

  it("uses located executable paths for executable harnesses", async () => {
    const connector = makeConnector()
    const runtime = makeAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => name === "opencode",
      locateExecutable: (name) => (name === "opencode" ? "/opt/herdman/bin/opencode" : undefined)
    })

    await run(runtime.createAgentSession("opencode", "/tmp/project", () => undefined))

    expect(connector.requests[0]).toMatchObject({
      args: ["acp"],
      command: "/opt/herdman/bin/opencode",
      cwd: "/tmp/project",
      harnessId: "opencode"
    })
  })

  it("constructs the Effect service layer and handles missing PATH", async () => {
    await expect(run(makeAgentRuntime().discoverHarnesses)).resolves.toEqual(expect.any(Array))

    const layeredHarnesses = await run(
      Effect.gen(function* () {
        const runtime = yield* AgentRuntime
        return yield* runtime.discoverHarnesses
      }).pipe(Effect.provide(AgentRuntime.layer({ env: {} })))
    )
    expect(layeredHarnesses.every((harness) => harness.readiness.state === "unavailable")).toBe(
      true
    )

    const runtime = makeAgentRuntime({ env: {} })
    expect((await run(runtime.discoverHarnesses))[0]?.readiness.detail).toBe(
      "CLI not found on PATH"
    )
  })

  it("streams turn lifecycle and session output through the persistent sink", async () => {
    const connector = makeConnector()
    const runtime = makeAgentRuntime({
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

  it("delivers events that arrive with no prompt in flight", async () => {
    // Regression test for the dropped-background-events bug: the sink used to
    // exist only for the duration of a prompt request.
    const connector = makeConnector()
    const runtime = makeAgentRuntime({
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

    expect(events).toEqual([
      conversationEvent(sessionId, "assistant", "background task finished")
    ])
  })

  it("keeps per-session event order through the serial sink chain", async () => {
    const connector = makeConnector()
    const runtime = makeAgentRuntime({
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
    const runtime = makeAgentRuntime({
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
    await run(runtime.setConfigOption(sessionId, "model", "gpt-5"))

    expect(connector.connections[0]?.cancellations).toEqual([sessionId])
    expect(events).toHaveLength(2)
    expect(events[0]).toMatchObject({
      kind: "session.updated",
      payload: { modeId: "plan" }
    })
    expect(events[1]).toMatchObject({
      kind: "session.updated",
      payload: { configId: "model", value: "gpt-5" }
    })
  })

  it("reports unavailable or unknown harnesses before connecting", async () => {
    const connector = makeConnector()
    const runtime = makeAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: () => false
    })

    await expect(
      run(runtime.createAgentSession("gemini", "/tmp/project", () => undefined))
    ).rejects.toThrow("ACP harness is unavailable")
    await expect(
      run(runtime.createAgentSession("missing", "/tmp/project", () => undefined))
    ).rejects.toThrow("Unknown harness")
    expect(connector.requests).toEqual([])
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

  it("attaches diff stats to tool-call updates carrying diff content", () => {
    const event = runtimeEventFromNotification({
      sessionId: "session-1",
      update: {
        sessionUpdate: "tool_call_update",
        toolCallId: "tool-1",
        status: "completed",
        content: [
          {
            type: "diff",
            path: "/tmp/a.txt",
            oldText: "one\ntwo\n",
            newText: "one\nthree\nfour\n"
          }
        ]
      }
    } as never)

    expect(event.kind).toBe("session.output")
    expect(event.payload).toMatchObject({
      toolCallId: "tool-1",
      diffStats: [{ added: 2, path: "/tmp/a.txt", removed: 1 }]
    })

    const plain = runtimeEventFromNotification({
      sessionId: "session-1",
      update: {
        sessionUpdate: "tool_call",
        toolCallId: "tool-2",
        title: "Read file"
      }
    } as never)
    expect(plain.payload).not.toHaveProperty("diffStats")
  })
})

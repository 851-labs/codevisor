import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import {
  AcpRuntime,
  acpProtocolVersion,
  makeAcpRuntime,
  toEventEnvelope,
  type AcpAgentConnection,
  type AcpConnector,
  type AcpHarnessLaunchRequest,
  type AcpRuntimeError,
  type PromptResult,
  type RuntimeEvent,
  type RuntimeEventSink
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

  constructor(readonly request: AcpHarnessLaunchRequest) {
    this.failClose = request.cwd.includes("fail-close")
  }

  createSession(
    cwd: string
  ): Effect.Effect<{ readonly sessionId: string; readonly configOptions: [] }, AcpRuntimeError> {
    return Effect.sync(() => {
      const sessionId = `agent-${this.request.harnessId}-${this.created.length + 1}`
      this.created.push(cwd)
      return { configOptions: [], sessionId }
    })
  }

  loadSession(sessionId: string, cwd: string): Effect.Effect<string, AcpRuntimeError> {
    return Effect.sync(() => {
      this.loaded.push([sessionId, cwd])
      return sessionId
    })
  }

  prompt(
    sessionId: string,
    text: string,
    onEvent?: RuntimeEventSink
  ): Effect.Effect<PromptResult, AcpRuntimeError> {
    return Effect.promise(async () => {
      this.prompts.push([sessionId, text])
      const events = [
        conversationEvent(sessionId, "user", text),
        conversationEvent(sessionId, "assistant", `Echo: ${text}`)
      ]
      for (const event of events) {
        await onEvent?.(event)
      }
      return {
        events: onEvent === undefined ? events : [],
        stopReason: "end_turn"
      }
    })
  }

  cancel(sessionId: string): Effect.Effect<RuntimeEvent, AcpRuntimeError> {
    return Effect.sync(() => {
      this.cancellations.push(sessionId)
      return {
        kind: "session.updated",
        subjectId: sessionId,
        payload: { stopReason: "cancelled" }
      }
    })
  }

  setMode(sessionId: string, modeId: string): Effect.Effect<RuntimeEvent, AcpRuntimeError> {
    return Effect.sync(() => {
      this.modes.push([sessionId, modeId])
      return {
        kind: "session.updated",
        subjectId: sessionId,
        payload: { modeId }
      }
    })
  }

  setConfigOption(
    sessionId: string,
    configId: string,
    value: string
  ): Effect.Effect<RuntimeEvent, AcpRuntimeError> {
    return Effect.sync(() => {
      this.configs.push([sessionId, configId, value])
      return {
        kind: "session.updated",
        subjectId: sessionId,
        payload: { configId, value }
      }
    })
  }

  readonly close: Effect.Effect<void, AcpRuntimeError> = Effect.sync(() => {
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
    connect: (request) =>
      Effect.sync(() => {
        requests.push(request)
        const connection = new FakeConnection(request)
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

describe("@herdman/acp-runtime", () => {
  it("discovers ready, missing-runner, and unavailable harnesses", async () => {
    const runtime = makeAcpRuntime({
      env: { PATH: "/bin" },
      executableExists: (name) => ["codex", "opencode"].includes(name)
    })

    const harnesses = await run(runtime.discoverHarnesses)
    expect(harnesses.find((harness) => harness.id === "codex")?.readiness).toEqual({
      state: "unavailable",
      detail: "Requires npx"
    })
    expect(harnesses.find((harness) => harness.id === "opencode")?.readiness).toEqual({
      state: "ready"
    })
    expect(harnesses.find((harness) => harness.id === "claude-code")?.readiness.detail).toBe(
      "CLI not found on PATH"
    )
    expect(harnesses.find((harness) => harness.id === "factory-droid")?.launchKind).toBe("npx")
  })

  it("creates and loads agent sessions through the connector", async () => {
    const connector = makeConnector()
    const runtime = makeAcpRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => ["codex", "npx"].includes(name),
      locateExecutable: (name) => `/bin/${name}`
    })

    const created = await run(runtime.createAgentSession("codex", "/tmp/project"))
    const inspected = await run(runtime.inspectHarness("codex", "/tmp/project"))
    const inspectedWithCloseFailure = await run(runtime.inspectHarness("codex", "/tmp/fail-close"))
    const loaded = await run(runtime.loadAgentSession("codex", "agent-existing", "/tmp/project"))
    const loadedAgain = await run(
      runtime.loadAgentSession("codex", "agent-existing", "/tmp/project")
    )
    const previousLoadedConnection = connector.connections[3]
    if (previousLoadedConnection === undefined) {
      throw new Error("expected a loaded fake connection")
    }
    previousLoadedConnection.failClose = true
    const reloadedElsewhere = await run(
      runtime.loadAgentSession("codex", "agent-existing", "/tmp/other")
    )
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(created).toBe("agent-codex-1")
    expect(inspected).toEqual({ configOptions: [], sessionId: "agent-codex-1" })
    expect(inspectedWithCloseFailure).toEqual({ configOptions: [], sessionId: "agent-codex-1" })
    expect(loaded).toBe("agent-existing")
    expect(loadedAgain).toBe("agent-existing")
    expect(reloadedElsewhere).toBe("agent-existing")
    expect(connector.requests).toHaveLength(5)
    expect(connector.requests[0]).toMatchObject({
      args: ["-y", "@agentclientprotocol/codex-acp@1.0.2"],
      command: "/bin/npx",
      cwd: "/tmp/project",
      harnessId: "codex"
    })
    expect(connector.connections[3]?.loaded).toEqual([["agent-existing", "/tmp/project"]])
    expect(previousLoadedConnection.closeCount).toBe(1)
    expect(connector.connections[4]?.loaded).toEqual([["agent-existing", "/tmp/other"]])
  })

  it("falls back to executable names when PATH lookup is delegated", async () => {
    const connector = makeConnector()
    const runtime = makeAcpRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => ["codex", "npx", "opencode"].includes(name),
      locateExecutable: () => undefined
    })

    await run(runtime.createAgentSession("codex", "/tmp/project"))
    await run(runtime.createAgentSession("opencode", "/tmp/project"))

    expect(connector.requests.map((request) => request.command)).toEqual(["npx", "opencode"])
    expect(connector.requests[1]?.args).toEqual(["acp"])
  })

  it("uses located executable paths for executable harnesses", async () => {
    const connector = makeConnector()
    const runtime = makeAcpRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => name === "opencode",
      locateExecutable: (name) => (name === "opencode" ? "/opt/herdman/bin/opencode" : undefined)
    })

    await run(runtime.createAgentSession("opencode", "/tmp/project"))

    expect(connector.requests[0]).toMatchObject({
      args: ["acp"],
      command: "/opt/herdman/bin/opencode",
      cwd: "/tmp/project",
      harnessId: "opencode"
    })
  })

  it("constructs the Effect service layer and handles missing PATH", async () => {
    await expect(run(makeAcpRuntime().discoverHarnesses)).resolves.toEqual(expect.any(Array))

    const layeredHarnesses = await run(
      Effect.gen(function* () {
        const runtime = yield* AcpRuntime
        return yield* runtime.discoverHarnesses
      }).pipe(Effect.provide(AcpRuntime.layer({ env: {} })))
    )
    expect(layeredHarnesses.every((harness) => harness.readiness.state === "unavailable")).toBe(
      true
    )

    const runtime = makeAcpRuntime({ env: {} })
    expect((await run(runtime.discoverHarnesses))[0]?.readiness.detail).toBe(
      "CLI not found on PATH"
    )
  })

  it("routes prompt and control operations to loaded ACP sessions", async () => {
    const connector = makeConnector()
    const runtime = makeAcpRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => ["codex", "npx"].includes(name),
      locateExecutable: (name) => `/bin/${name}`
    })
    const sessionId = await run(runtime.createAgentSession("codex", "/tmp/project"))

    const result = await run(runtime.prompt(sessionId, "hello"))
    expect(result.stopReason).toBe("end_turn")
    expect(result.events).toEqual([
      conversationEvent(sessionId, "user", "hello"),
      conversationEvent(sessionId, "assistant", "Echo: hello")
    ])
    expect(connector.connections[0]?.prompts).toEqual([[sessionId, "hello"]])
    const liveEvents: Array<RuntimeEvent> = []
    const liveResult = await run(
      runtime.prompt(sessionId, "stream", (event) => {
        liveEvents.push(event)
      })
    )
    expect(liveResult).toEqual({ events: [], stopReason: "end_turn" })
    expect(liveEvents).toEqual([
      conversationEvent(sessionId, "user", "stream"),
      conversationEvent(sessionId, "assistant", "Echo: stream")
    ])
    expect(await run(runtime.cancel(sessionId))).toMatchObject({
      kind: "session.updated",
      payload: { stopReason: "cancelled" }
    })
    expect(await run(runtime.setMode(sessionId, "plan"))).toMatchObject({
      payload: { modeId: "plan" }
    })
    expect(await run(runtime.setConfigOption(sessionId, "model", "gpt-5"))).toMatchObject({
      payload: { configId: "model", value: "gpt-5" }
    })

    await expect(run(runtime.prompt("missing", "hello"))).rejects.toThrow(
      "ACP session is not loaded"
    )
  })

  it("reports unavailable or unknown harnesses before connecting", async () => {
    const connector = makeConnector()
    const runtime = makeAcpRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: () => false
    })

    await expect(run(runtime.createAgentSession("codex", "/tmp/project"))).rejects.toThrow(
      "ACP harness is unavailable"
    )
    await expect(run(runtime.createAgentSession("missing", "/tmp/project"))).rejects.toThrow(
      "Unknown ACP harness"
    )
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
})

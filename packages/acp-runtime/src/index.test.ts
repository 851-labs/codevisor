import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { AcpRuntime, acpProtocolVersion, makeAcpRuntime, toEventEnvelope } from "./index.js"

const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

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
  })

  it("creates and loads agent sessions", async () => {
    const runtime = makeAcpRuntime()
    const created = await run(runtime.createAgentSession("codex", "/tmp/project"))
    const loaded = await run(runtime.loadAgentSession("codex", "agent-existing", "/tmp/project"))
    expect(created.startsWith("agent_")).toBe(true)
    expect(loaded).toBe("agent-existing")
  })

  it("constructs the Effect layer and handles missing PATH", async () => {
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

  it("produces prompt and control events", async () => {
    const runtime = makeAcpRuntime()
    const result = await run(runtime.prompt("session-1", "hello"))
    expect(result.stopReason).toBe("end_turn")
    expect(result.events).toHaveLength(2)
    expect(result.events[1]?.payload).toMatchObject({ protocolVersion: acpProtocolVersion })
    expect(await run(runtime.cancel("session-1"))).toMatchObject({
      kind: "session.updated",
      payload: { stopReason: "cancelled" }
    })
    expect(await run(runtime.setMode("session-1", "plan"))).toMatchObject({
      payload: { modeId: "plan" }
    })
    expect(await run(runtime.setConfigOption("session-1", "model", "gpt-5"))).toMatchObject({
      payload: { configId: "model", value: "gpt-5" }
    })
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
  })
})

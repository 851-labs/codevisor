import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import type { RuntimeEmit, RuntimeEvent } from "@codevisor/agent-runtime"
import { makeAcpAgentRuntime, run } from "./test-support.js"

describe("agent runtime account handoff", () => {
  it("fully retires an account handle before loading its replacement", async () => {
    const sessionId = "account-handoff"
    const oldEvents: Array<RuntimeEvent> = []
    const replacementEvents: Array<RuntimeEvent> = []
    const order: Array<string> = []
    let oldEmit: RuntimeEmit | undefined
    let replacementEmit: RuntimeEmit | undefined
    let closeStarted: (() => void) | undefined
    let releaseClose: (() => void) | undefined
    const closeStartedGate = new Promise<void>((resolvePromise) => {
      closeStarted = resolvePromise
    })
    const closeGate = new Promise<void>((resolvePromise) => {
      releaseClose = resolvePromise
    })
    const replacementHandle = {
      cancel: Effect.succeed({ runtimeState: "reusable" as const }),
      close: Effect.void,
      prompt: () => Effect.succeed({ stopReason: "end_turn" }),
      setConfigOption: () => Effect.succeed([]),
      setMode: () => Effect.void
    }
    const oldHandle = {
      ...replacementHandle,
      close: Effect.promise(async () => {
        order.push("close:start")
        closeStarted?.()
        await closeGate
        await oldEmit?.({
          kind: "session.error",
          payload: { message: "Operation aborted" },
          subjectId: sessionId
        })
        order.push("close:end")
      })
    }
    const custom = {
      createSession: (_definition: unknown, _cwd: unknown, emit: RuntimeEmit) =>
        Effect.sync(() => {
          oldEmit = emit
          return {
            handle: oldHandle,
            metadata: { configOptions: [], sessionId }
          }
        }),
      id: "claude" as const,
      loadSession: (
        _definition: unknown,
        loadedSessionId: string,
        _cwd: unknown,
        emit: RuntimeEmit
      ) =>
        Effect.sync(() => {
          order.push("load")
          replacementEmit = emit
          return { handle: replacementHandle, sessionId: loadedSessionId }
        }),
      readiness: () => ({ state: "ready" }) as const
    }
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: () => true,
      locateExecutable: (name) => `/bin/${name}`,
      providers: { claude: custom as never }
    })
    await run(
      runtime.createAgentSession(
        "claude-code",
        "/tmp/project",
        (event) => {
          oldEvents.push(event)
        },
        {
          id: "old-account",
          profileKind: "managed"
        }
      )
    )

    const replacement = run(
      runtime.loadAgentSession(
        "claude-code",
        sessionId,
        "/tmp/project",
        (event) => {
          replacementEvents.push(event)
        },
        { id: "new-account", profileKind: "default" }
      )
    )
    await closeStartedGate

    expect(order).toEqual(["close:start"])
    expect(replacementEmit).toBeUndefined()
    releaseClose?.()
    await expect(replacement).resolves.toEqual({ configOptions: [], sessionId })
    expect(order).toEqual(["close:start", "close:end", "load"])
    expect(oldEvents).toEqual([])
    expect(replacementEvents).toEqual([])

    // Even a provider callback that escapes close cannot cross generations.
    await oldEmit?.({
      kind: "session.error",
      payload: { message: "late old-account error" },
      subjectId: sessionId
    })
    await replacementEmit?.({
      kind: "session.output",
      payload: { role: "assistant", text: "new-account response" },
      subjectId: sessionId
    })
    expect(replacementEvents).toEqual([
      expect.objectContaining({ payload: { role: "assistant", text: "new-account response" } })
    ])
  })

  it("keeps a newer session installed while the old event sink drains", async () => {
    const sessionId = "event-time-replacement"
    let initialEmit: RuntimeEmit | undefined
    let createCount = 0
    let loadCount = 0
    let sinkStarted: (() => void) | undefined
    let releaseSink: (() => void) | undefined
    const sinkStartedGate = new Promise<void>((resolvePromise) => {
      sinkStarted = resolvePromise
    })
    const sinkGate = new Promise<void>((resolvePromise) => {
      releaseSink = resolvePromise
    })
    const initialHandle = {
      cancel: Effect.succeed({ runtimeState: "reusable" as const }),
      close: Effect.fail(new Error("expected retired close failure")),
      prompt: () => Effect.succeed({ stopReason: "initial" }),
      setConfigOption: () => Effect.succeed([]),
      setMode: () => Effect.void
    }
    const concurrentHandle = {
      ...initialHandle,
      close: Effect.void,
      prompt: () => Effect.succeed({ stopReason: "concurrent" })
    }
    const loadedHandle = {
      ...concurrentHandle,
      prompt: () => Effect.succeed({ stopReason: "loaded" })
    }
    const custom = {
      createSession: (_definition: unknown, _cwd: unknown, emit: RuntimeEmit) =>
        Effect.sync(() => {
          if (createCount === 0) initialEmit = emit
          return {
            handle: createCount++ === 0 ? initialHandle : concurrentHandle,
            metadata: { configOptions: [], sessionId }
          }
        }),
      id: "claude" as const,
      loadSession: () =>
        Effect.sync(() => {
          loadCount += 1
          return { handle: loadedHandle, sessionId }
        }),
      readiness: () => ({ state: "ready" }) as const
    }
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: () => true,
      locateExecutable: (name) => `/bin/${name}`,
      providers: { claude: custom as never }
    })
    await run(
      runtime.createAgentSession(
        "claude-code",
        "/tmp/project",
        async () => {
          sinkStarted?.()
          await sinkGate
          await run(
            runtime.createAgentSession("claude-code", "/tmp/project", () => undefined, {
              id: "event-account",
              profileKind: "managed"
            })
          )
        },
        { id: "old-account", profileKind: "managed" }
      )
    )

    const draining = initialEmit?.({
      kind: "session.output",
      payload: { role: "assistant", text: "draining" },
      subjectId: sessionId
    })
    await sinkStartedGate
    const loading = run(
      runtime.loadAgentSession("claude-code", sessionId, "/tmp/project", () => undefined, {
        id: "new-account",
        profileKind: "managed"
      })
    )
    releaseSink?.()
    await draining
    await loading

    expect(createCount).toBe(2)
    expect(loadCount).toBe(1)
    await expect(run(runtime.prompt(sessionId, "hello"))).resolves.toEqual({
      stopReason: "loaded"
    })
  })
})

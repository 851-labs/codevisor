import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { makeAgentRuntime, type RuntimeEmit } from "@codevisor/agent-runtime"
import { makeAcpAgentRuntime, makeConnector, run } from "./test-support.js"

describe("@codevisor/agent-runtime", () => {
  it("creates and loads agent sessions through the connector", async () => {
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => name === "gemini",
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
    expect(loaded).toEqual({ configOptions: [], sessionId: "agent-existing" })
    expect(loadedAgain).toEqual({ configOptions: [], sessionId: "agent-existing" })
    expect(reloadedElsewhere).toEqual({ configOptions: [], sessionId: "agent-existing" })
    expect(connector.requests).toHaveLength(5)
    expect(connector.requests[0]).toMatchObject({
      args: ["--acp"],
      command: "/bin/gemini",
      cwd: "/tmp/project",
      harnessId: "gemini"
    })
    expect(connector.connections[0]?.created).toEqual(["/tmp/project"])
    expect(connector.connections[3]?.loaded).toEqual([["agent-existing", "/tmp/project"]])
    expect(previousLoadedConnection.closeCount).toBe(1)
    expect(connector.connections[4]?.loaded).toEqual([["agent-existing", "/tmp/other"]])
  })

  it("launches Pi through the pinned ACP adapter", async () => {
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => ["npx", "pi"].includes(name),
      locateExecutable: (name) => `/bin/${name}`
    })

    const sessionId = await run(
      runtime.createAgentSession("pi", "/tmp/pi-project", () => undefined)
    )

    expect(sessionId).toBe("agent-pi-1")
    expect(connector.requests[0]).toMatchObject({
      args: ["-y", "pi-acp@0.0.31"],
      command: "/bin/npx",
      cwd: "/tmp/pi-project",
      harnessId: "pi"
    })
    await run(runtime.closeAgentSession(sessionId))
  })

  it("times out hung harness inspection and closes its connection", async () => {
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => name === "gemini",
      harnessInspectionTimeoutMs: 10,
      locateExecutable: (name) => `/bin/${name}`
    })

    await expect(
      run(runtime.inspectHarness("gemini", "/tmp/hang-inspection"))
    ).rejects.toMatchObject({
      message: "Harness inspection timed out after 10ms",
      operation: "inspectHarness"
    })
    expect(connector.connections[0]?.closeCount).toBe(1)
  })

  it("maps harness inspection failures and closes their connection", async () => {
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => name === "gemini",
      locateExecutable: (name) => `/bin/${name}`
    })

    await expect(
      run(runtime.inspectHarness("gemini", "/tmp/fail-inspection"))
    ).rejects.toMatchObject({
      message: "Inspection setup failed",
      operation: "inspectHarness"
    })
    expect(connector.connections[0]?.closeCount).toBe(1)
  })

  it("closes a loaded agent session and forgets it", async () => {
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => name === "gemini",
      locateExecutable: (name) => `/bin/${name}`
    })
    const sessionId = await run(
      runtime.createAgentSession("gemini", "/tmp/project", () => undefined)
    )

    // Closing a session that is not loaded is a no-op (archives of sessions
    // never opened this server-lifetime have nothing to tear down).
    await run(runtime.closeAgentSession("missing"))
    await expect(run(runtime.cancel("missing"))).rejects.toMatchObject({
      operation: "cancel"
    })
    expect(connector.connections[0]?.closeCount).toBe(0)

    await run(runtime.closeAgentSession(sessionId))
    expect(connector.connections[0]?.closeCount).toBe(1)
    await expect(run(runtime.prompt(sessionId, "hello"))).rejects.toMatchObject({
      operation: "sessionFor"
    })
  })

  it("forgets a session even when closing its handle fails", async () => {
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => name === "gemini",
      locateExecutable: (name) => `/bin/${name}`
    })
    const sessionId = await run(
      runtime.createAgentSession("gemini", "/tmp/fail-close", () => undefined)
    )

    await expect(run(runtime.closeAgentSession(sessionId))).rejects.toMatchObject({
      message: "close failed",
      operation: "closeAgentSession"
    })
    await expect(run(runtime.prompt(sessionId, "hello"))).rejects.toMatchObject({
      operation: "sessionFor"
    })
  })

  it("falls back to executable names when PATH lookup is delegated", async () => {
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => ["gemini", "opencode"].includes(name),
      locateExecutable: () => undefined
    })
    const sink = (): void => undefined

    await run(runtime.createAgentSession("gemini", "/tmp/project", sink))
    await run(runtime.createAgentSession("opencode", "/tmp/project", sink))

    expect(connector.requests.map((request) => request.command)).toEqual(["gemini", "opencode"])
    expect(connector.requests[0]?.args).toEqual(["--acp"])
    expect(connector.requests[1]?.args).toEqual(["acp"])
  })

  it("uses located executable paths for executable harnesses", async () => {
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => name === "opencode",
      locateExecutable: (name) => (name === "opencode" ? "/opt/codevisor/bin/opencode" : undefined)
    })

    await run(runtime.createAgentSession("opencode", "/tmp/project", () => undefined))

    expect(connector.requests[0]).toMatchObject({
      args: ["acp"],
      command: "/opt/codevisor/bin/opencode",
      cwd: "/tmp/project",
      harnessId: "opencode"
    })
  })

  it("reports unavailable or unknown harnesses before connecting", async () => {
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
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

  it("flushes and retires only the cancelled handle before loading a replacement", async () => {
    const sessionId = "retiring-session"
    let emit: RuntimeEmit | undefined
    let closeCount = 0
    let loadCount = 0
    let terminalEntered = false
    let releaseTerminal: (() => void) | undefined
    let cancelSettled = false
    const terminalGate = new Promise<void>((resolvePromise) => {
      releaseTerminal = resolvePromise
    })
    const handle = (runtimeState: "reusable" | "retire") => ({
      cancel: Effect.promise(async () => {
        await emit?.({
          kind: "session.updated",
          payload: { stopReason: "cancelled", turnState: "ended" },
          subjectId: sessionId
        })
        return { runtimeState }
      }),
      close: Effect.sync(() => {
        closeCount += 1
      }),
      prompt: () => Effect.succeed({ stopReason: "end_turn" }),
      setConfigOption: () => Effect.succeed([]),
      setMode: () => Effect.void
    })
    const initialHandle = handle("retire")
    const replacementHandle = handle("reusable")
    const custom = {
      createSession: (_definition: unknown, _cwd: unknown, runtimeEmit: RuntimeEmit) =>
        Effect.sync(() => {
          emit = runtimeEmit
          return {
            handle: initialHandle,
            metadata: { configOptions: [], sessionId }
          }
        }),
      id: "claude" as const,
      loadSession: (
        _definition: unknown,
        loadedSessionId: string,
        _cwd: unknown,
        runtimeEmit: RuntimeEmit
      ) =>
        Effect.sync(() => {
          loadCount += 1
          emit = runtimeEmit
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
      runtime.createAgentSession("claude-code", "/tmp/project", async (event) => {
        const payload = event.payload as Record<string, unknown>
        if (payload.turnState === "ended") {
          terminalEntered = true
          await terminalGate
        }
      })
    )

    const cancellation = run(runtime.cancel(sessionId)).then(() => {
      cancelSettled = true
    })
    while (!terminalEntered)
      await new Promise<void>((resolvePromise) => setImmediate(resolvePromise))
    const replacement = run(
      runtime.loadAgentSession("claude-code", sessionId, "/tmp/project", () => Promise.resolve())
    )
    await new Promise<void>((resolvePromise) => setImmediate(resolvePromise))
    expect(cancelSettled).toBe(false)
    expect(loadCount).toBe(0)

    releaseTerminal?.()
    await cancellation
    await expect(replacement).resolves.toEqual({ configOptions: [], sessionId })
    expect(closeCount).toBe(1)
    expect(loadCount).toBe(1)

    // The freshly loaded matching handle remains managed; stale retirement
    // cleanup cannot remove it.
    await run(runtime.cancel(sessionId))
    expect(closeCount).toBe(1)
  })

  it("forgets a retired session even when closing its handle fails", async () => {
    const sessionId = "retire-close-failure"
    const handle = {
      cancel: Effect.succeed({ runtimeState: "retire" as const }),
      close: Effect.fail(new Error("retired close failed")),
      prompt: () => Effect.succeed({ stopReason: "end_turn" }),
      setConfigOption: () => Effect.succeed([]),
      setMode: () => Effect.void
    }
    const custom = {
      createSession: () =>
        Effect.succeed({
          handle,
          metadata: { configOptions: [], sessionId }
        }),
      id: "claude" as const,
      loadSession: () => Effect.die("unused"),
      readiness: () => ({ state: "ready" }) as const
    }
    const runtime = makeAcpAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: () => true,
      locateExecutable: (name) => `/bin/${name}`,
      providers: { claude: custom as never }
    })
    await run(runtime.createAgentSession("claude-code", "/tmp/project", () => undefined))

    await expect(run(runtime.cancel(sessionId))).rejects.toMatchObject({
      message: "retired close failed",
      operation: "cancel"
    })
    await expect(run(runtime.prompt(sessionId, "hello"))).rejects.toMatchObject({
      operation: "sessionFor"
    })
  })

  it.each(["cancel", "closeAgentSession"] as const)(
    "keeps a replacement created while %s cleans up the previous handle",
    async (operation) => {
      const sessionId = `replacement-during-${operation}`
      let createCount = 0
      let initialCloseCount = 0
      let runtime: ReturnType<typeof makeAgentRuntime>
      const replacementHandle = {
        cancel: Effect.succeed({ runtimeState: "reusable" as const }),
        close: Effect.void,
        prompt: () => Effect.succeed({ stopReason: "replacement" }),
        setConfigOption: () => Effect.succeed([]),
        setMode: () => Effect.void
      }
      const initialHandle = {
        cancel: Effect.succeed({ runtimeState: "retire" as const }),
        close: Effect.promise(async () => {
          initialCloseCount += 1
          if (initialCloseCount === 1) {
            await run(runtime.createAgentSession("claude-code", "/tmp/project", () => undefined))
          }
        }),
        prompt: () => Effect.succeed({ stopReason: "initial" }),
        setConfigOption: () => Effect.succeed([]),
        setMode: () => Effect.void
      }
      const custom = {
        createSession: () =>
          Effect.sync(() => ({
            handle: createCount++ === 0 ? initialHandle : replacementHandle,
            metadata: { configOptions: [], sessionId }
          })),
        id: "claude" as const,
        loadSession: () => Effect.die("unused"),
        readiness: () => ({ state: "ready" }) as const
      }
      runtime = makeAcpAgentRuntime({
        env: { PATH: "/bin" },
        executableExists: () => true,
        locateExecutable: (name) => `/bin/${name}`,
        providers: { claude: custom as never }
      })
      await run(runtime.createAgentSession("claude-code", "/tmp/project", () => undefined))

      await run(runtime[operation](sessionId))

      expect(createCount).toBe(2)
      await expect(run(runtime.prompt(sessionId, "hello"))).resolves.toEqual({
        stopReason: "replacement"
      })
    }
  )
})

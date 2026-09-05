import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"
import { AgentRuntimeError, type RuntimeEmit } from "@codevisor/agent-runtime"
import { testAcpConnection, type AcpHarnessLaunchRequest } from "./index.js"
import { FakeConnection, makeAcpAgentRuntime, makeConnector, run } from "./test-support.js"

describe("@codevisor/agent-runtime", () => {
  afterEach(() => vi.useRealTimers())
  it("probes and delegates harness authentication", async () => {
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => name === "gemini",
      locateExecutable: (name) => `/bin/${name}`
    })
    const account = {
      id: "account-1",
      profileKind: "managed" as const,
      env: { TEST_PROFILE: "account-1" }
    }

    await expect(run(runtime.probeHarnessAuth("gemini", account))).resolves.toEqual({
      state: "notRequired",
      methods: [],
      canLogout: false
    })
    await expect(run(runtime.authenticateHarness("gemini", "browser", account))).resolves.toBe(
      undefined
    )
    await expect(run(runtime.logoutHarness("gemini", account))).resolves.toBe(undefined)
    expect(connector.requests.every((request) => request.env.TEST_PROFILE === "account-1")).toBe(
      true
    )
    expect(connector.connections.every((connection) => connection.closeCount === 1)).toBe(true)
    const sessionId = await run(
      runtime.createAgentSession("gemini", "/tmp/auth-profile", () => Promise.resolve(), account)
    )
    await run(runtime.closeAgentSession(sessionId))

    await expect(run(runtime.probeHarnessAuth("codex"))).resolves.toEqual({
      state: "notRequired",
      methods: [],
      canLogout: false
    })
    await expect(run(runtime.authenticateHarness("codex", "browser"))).rejects.toMatchObject({
      operation: "authenticate"
    })
    await expect(run(runtime.logoutHarness("codex"))).rejects.toMatchObject({
      operation: "logout"
    })
  })

  it("times out a hung ACP auth probe and closes its connection", async () => {
    vi.useFakeTimers()
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
      acpAuthProbeTimeoutMs: 10,
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => name === "gemini",
      locateExecutable: (name) => `/bin/${name}`
    })

    const timedOut = expect(
      run(
        runtime.probeHarnessAuth("gemini", {
          env: { HANG_AUTH: "1" },
          id: "hung-account",
          profileKind: "default"
        })
      )
    ).rejects.toMatchObject({
      message: "ACP authentication probe timed out after 10ms",
      operation: "probeAuth"
    })
    await vi.advanceTimersByTimeAsync(10)
    await timedOut
    expect(connector.connections[0]?.closeCount).toBe(1)
  })

  it("tests an ACP connection through the injected connector", async () => {
    const connector = makeConnector()
    const result = await testAcpConnection(
      { args: ["acp"], command: "my-agent", env: { EXTRA: "1" } },
      { connector, env: { PATH: "/bin" } }
    )
    expect(result).toEqual({ ok: true })
    expect(connector.requests[0]).toMatchObject({
      args: ["acp"],
      command: "my-agent",
      env: { EXTRA: "1", PATH: "/bin" },
      harnessId: "custom-harness-test"
    })
    // The probe tears its process down.
    expect(connector.connections[0]?.closeCount).toBe(1)
  })

  it("reports handshake identity and surfaces failures without throwing", async () => {
    const connector = makeConnector()
    const identified = {
      ...connector,
      connect: (request: AcpHarnessLaunchRequest, emit: RuntimeEmit) =>
        Effect.map(connector.connect(request, emit), (connection) => {
          ;(connection as FakeConnection).agentInfo = {
            name: "My Agent",
            protocolVersion: 1
          }
          return connection
        })
    }
    await expect(
      testAcpConnection({ args: [], command: "my-agent" }, { connector: identified, env: {} })
    ).resolves.toEqual({ agentName: "My Agent", ok: true, protocolVersion: 1 })

    const failing = {
      connect: () =>
        Effect.fail(
          new AgentRuntimeError({ message: "spawn my-agent ENOENT", operation: "connect" })
        )
    }
    const failure = await testAcpConnection(
      { args: [], command: "my-agent" },
      { connector: failing, env: {} }
    )
    expect(failure.ok).toBe(false)
    expect(failure.error).toContain("ENOENT")
  })

  it("lists native agent sessions through the provider hook", async () => {
    const fixture = [{ sessionId: "abc", cwd: "/repo", title: "Hi" }]
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: () => true,
      providers: {
        claude: {
          id: "claude",
          readiness: () => ({ state: "ready" }),
          createSession: () => Effect.die("unused"),
          loadSession: () => Effect.die("unused"),
          listAgentSessions: () => Promise.resolve(fixture)
        }
      }
    })

    await expect(run(runtime.listAgentSessions("claude-code"))).resolves.toEqual(fixture)
    await expect(run(runtime.listAgentSessions("gemini"))).resolves.toEqual([
      { cwd: "/repo", sessionId: "native-session", title: "Harness title" }
    ])
    expect(connector.connections.at(-1)?.closeCount).toBe(1)
    await expect(run(runtime.listAgentSessions("nope"))).rejects.toThrow("Unknown harness: nope")
  })

  it("reads provider usage limits and reports unsupported harnesses", async () => {
    const account = {
      id: "account-1",
      profileKind: "managed" as const,
      env: { TEST_PROFILE: "account-1" }
    }
    const runtime = makeAcpAgentRuntime({
      providers: {
        claude: {
          id: "claude",
          readiness: () => ({ state: "ready" }),
          createSession: () => Effect.die("unused"),
          loadSession: () => Effect.die("unused"),
          readUsageLimits: (definition, cwd, receivedAccount) =>
            Effect.succeed({
              accountId: receivedAccount?.id,
              fetchedAt: "2026-07-15T00:00:00.000Z",
              harnessId: definition.id,
              state: "available" as const,
              windows: [{ id: "five-hour", label: cwd, usedPercent: 25 }]
            })
        }
      }
    })

    await expect(
      run(runtime.readHarnessUsageLimits("claude-code", "/tmp/project", account))
    ).resolves.toEqual({
      accountId: "account-1",
      fetchedAt: "2026-07-15T00:00:00.000Z",
      harnessId: "claude-code",
      state: "available",
      windows: [{ id: "five-hour", label: "/tmp/project", usedPercent: 25 }]
    })
    await expect(
      run(runtime.readHarnessUsageLimits("gemini", "/tmp/project"))
    ).resolves.toMatchObject({
      detail: "This harness does not expose account usage limits.",
      harnessId: "gemini",
      state: "unavailable",
      windows: []
    })
    await expect(run(runtime.readHarnessUsageLimits("nope", "/tmp/project"))).rejects.toThrow(
      "Unknown harness: nope"
    )
    await expect(run(runtime.listAgentSessions("claude-code"))).resolves.toEqual([])
  })
})

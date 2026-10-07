import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"

import { makeAcpAgentRuntime, makeConnector, run } from "./test-support.js"

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

  it("lets the host catch credentials up before every turn, without failing one", async () => {
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => name === "gemini",
      locateExecutable: (name) => `/bin/${name}`
    })
    const order: string[] = []
    const beforeTurn = vi.fn(async () => {
      order.push(`refresh ${connector.connections[0]?.prompts.length ?? 0}`)
    })
    const account = { id: "account-1", profileKind: "managed" as const, beforeTurn }
    const sessionId = await run(
      runtime.createAgentSession("gemini", "/tmp/turns", () => Promise.resolve(), account)
    )
    expect(beforeTurn).not.toHaveBeenCalled()

    await run(runtime.prompt(sessionId, "one"))
    beforeTurn.mockRejectedValueOnce(new Error("vault offline"))
    await run(runtime.prompt(sessionId, "two"))
    await run(runtime.prompt(sessionId, "three"))

    // Each refresh lands before its prompt reaches the harness.
    expect(order).toEqual(["refresh 0", "refresh 2"])
    expect(beforeTurn).toHaveBeenCalledTimes(3)
    expect(connector.connections[0]?.prompts.map(([, text]) => text)).toEqual([
      "one",
      "two",
      "three"
    ])
    await run(runtime.closeAgentSession(sessionId))
  })

  it("times out a hung ACP auth probe and closes its connection", async () => {
    vi.useFakeTimers()
    const connector = makeConnector()
    const runtime = makeAcpAgentRuntime({
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
      message: "ACP authentication probe timed out after 10000ms",
      operation: "probeAuth"
    })
    await vi.advanceTimersByTimeAsync(10_000)
    await timedOut
    expect(connector.connections[0]?.closeCount).toBe(1)
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

import { Effect } from "effect"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import {
  AgentRuntime,
  AgentRuntimeError,
  acpConfigOptionIds,
  acpModelConfigId,
  acpModelConfigOption,
  acpReasoningEffortConfigOption,
  acpPermissionOutcome,
  acpPermissionQuestion,
  acpProtocolVersion,
  acpPrompt,
  applyAcpModelSelection,
  applyAcpReasoningEffortSelection,
  extractAcpModelState,
  extractPiStartupInfo,
  isPiStartupInfoNotification,
  grokAskUserQuestion,
  grokGoalNotification,
  grokModeState,
  grokPlanApprovalQuestion,
  harnessCatalog,
  locateExecutableOnPath,
  makeAgentRuntime,
  normalizeAcpConfigOptions,
  normalizeModeState,
  normalizePromptInput,
  piAssistantErrorFromSessionJsonl,
  runtimeEventFromNotification,
  testAcpConnection,
  toEventEnvelope,
  usesAcpModelSelectionExtension,
  withAttachmentNotes,
  type AcpAgentConnection,
  type AcpConnector,
  type AcpHarnessLaunchRequest,
  type PromptAttachmentInput,
  type PromptInput,
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
  agentInfo?: {
    readonly name?: string
    readonly version?: string
    readonly protocolVersion?: number
  }
  readonly listSessions = Effect.succeed([
    { cwd: "/repo", sessionId: "native-session", title: "Harness title" }
  ])

  constructor(
    readonly request: AcpHarnessLaunchRequest,
    readonly emit: RuntimeEmit
  ) {
    this.failClose = request.cwd.includes("fail-close")
  }

  probeAuth(): Effect.Effect<
    {
      readonly state: "notRequired"
      readonly methods: []
      readonly canLogout: false
    },
    AgentRuntimeError
  > {
    if (this.request.env.HANG_AUTH === "1") return Effect.never
    return Effect.succeed({ canLogout: false, methods: [], state: "notRequired" })
  }

  authenticate(_methodId: string): Effect.Effect<void, AgentRuntimeError> {
    return Effect.void
  }

  readonly logout: Effect.Effect<void, AgentRuntimeError> = Effect.void

  createSession(cwd: string): Effect.Effect<
    {
      readonly sessionId: string
      readonly configOptions: []
    },
    AgentRuntimeError
  > {
    if (cwd.includes("hang-inspection")) return Effect.never
    if (cwd.includes("fail-inspection")) {
      return Effect.fail(
        new AgentRuntimeError({ message: "Inspection setup failed", operation: "createSession" })
      )
    }
    return Effect.sync(() => {
      this.created.push(cwd)
      return { configOptions: [], sessionId: `agent-${this.request.harnessId}-1` }
    })
  }

  loadSession(
    sessionId: string,
    cwd: string
  ): Effect.Effect<{ readonly sessionId: string; readonly configOptions: [] }, AgentRuntimeError> {
    return Effect.sync(() => {
      this.loaded.push([sessionId, cwd])
      return { configOptions: [], sessionId }
    })
  }

  prompt(
    sessionId: string,
    input: string | PromptInput
  ): Effect.Effect<{ readonly stopReason: string }, AgentRuntimeError> {
    return Effect.promise(async () => {
      const { text } = normalizePromptInput(input)
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

describe("@codevisor/agent-runtime", () => {
  it("launches directly ACP-capable harnesses from the user's installation", () => {
    const directlyCapable = harnessCatalog.filter(
      (harness) => harness.provider === "acp" && harness.id !== "pi"
    )
    expect(directlyCapable.some((harness) => harness.launch?.kind === "npx")).toBe(false)
  })

  it("probes and delegates harness authentication", async () => {
    const connector = makeConnector()
    const runtime = makeAgentRuntime({
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
    const connector = makeConnector()
    const runtime = makeAgentRuntime({
      acpAuthProbeTimeoutMs: 10,
      connector,
      env: { PATH: "/bin" },
      executableExists: (name) => name === "gemini",
      locateExecutable: (name) => `/bin/${name}`
    })

    await expect(
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
    expect(connector.connections[0]?.closeCount).toBe(1)
  })

  it("discovers ready local executables and unavailable harnesses", async () => {
    const runtime = makeAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: (name) => ["gemini", "opencode", "codex"].includes(name),
      // Pinned so path/version enrichment stays off regardless of what is
      // installed on the machine running the tests (e.g. ChatGPT.app).
      locateExecutable: () => undefined,
      // Exercises the background-terminal threading into every provider.
      backgroundTerminals: {
        registry: { register: () => ({ exit: () => {}, output: () => {}, remove: () => {} }) }
      }
    })

    const harnesses = await run(runtime.discoverHarnesses)
    expect(harnesses.find((harness) => harness.id === "gemini")?.readiness).toEqual({
      state: "ready"
    })
    // Every catalog entry now launches the user's installed binary directly.
    expect(harnesses.find((harness) => harness.id === "codex")?.readiness).toEqual({
      state: "ready"
    })
    expect(harnesses.find((harness) => harness.id === "opencode")?.readiness).toEqual({
      state: "ready"
    })
    expect(harnesses.find((harness) => harness.id === "claude-code")?.readiness.detail).toBe(
      "CLI not found on PATH"
    )
    expect(harnesses.find((harness) => harness.id === "factory-droid")?.launchKind).toBe(
      "executable"
    )
    // Cursor is pulled until cursor-agent's ACP mode stabilizes upstream.
    expect(harnesses.find((harness) => harness.id === "cursor")?.readiness).toMatchObject({
      state: "unavailable",
      detail: expect.stringContaining("Temporarily disabled")
    })
    // Install hints ride along only for harnesses that define them.
    expect(harnesses.find((harness) => harness.id === "claude-code")?.installHint).toContain(
      "claude.ai/install.sh"
    )
    expect(harnesses.find((harness) => harness.id === "pi")?.installHint).toBe(
      "npm install -g @earendil-works/pi-coding-agent"
    )
    expect(harnesses.find((harness) => harness.id === "gemini")?.installHint).toBeUndefined()
  })

  it("enriches ready harnesses with the resolved path and probed version", async () => {
    const runtime = makeAgentRuntime({
      env: { PATH: "/opt/tools" },
      locateExecutable: (name) => (name === "claude" ? "/opt/tools/claude" : undefined),
      readVersionOutput: (path) =>
        path === "/opt/tools/claude"
          ? Promise.resolve("claude 2.1.5 (Claude Code)")
          : Promise.reject(new Error("unexpected probe"))
    })

    // Discovery resolves the path synchronously; versions only exist once a
    // refresh has probed them.
    const first = await run(runtime.discoverHarnesses)
    const claudeBefore = first.find((harness) => harness.id === "claude-code")
    expect(claudeBefore?.readiness).toMatchObject({ state: "ready", path: "/opt/tools/claude" })
    expect(claudeBefore?.readiness.version).toBeUndefined()

    // A refresh (the client's "Detect again") awaits probes even without an
    // env resolver, so the next discovery carries the version.
    await run(runtime.refreshEnvironment)
    const after = await run(runtime.discoverHarnesses)
    expect(after.find((harness) => harness.id === "claude-code")?.readiness).toEqual({
      state: "ready",
      path: "/opt/tools/claude",
      version: "2.1.5"
    })
    // Unavailable harnesses stay unenriched.
    expect(after.find((harness) => harness.id === "codex")?.readiness.path).toBeUndefined()
  })

  it("refreshes the environment so readiness picks up newly installed CLIs", async () => {
    let resolveCalls = 0
    const runtime = makeAgentRuntime({
      env: { PATH: "/before" },
      // Readiness is keyed off the live env's PATH: claude "installs" only
      // after refreshEnvironment swaps the env.
      executableExists: (name, env) => name === "claude" && env.PATH === "/after",
      // Pinned: the refresh's version probe must not locate (and spawn) real
      // binaries installed on the machine running the tests.
      locateExecutable: () => undefined,
      resolveEnv: () => {
        resolveCalls += 1
        return Promise.resolve({ PATH: "/after" })
      }
    })

    const before = await run(runtime.discoverHarnesses)
    expect(before.find((harness) => harness.id === "claude-code")?.readiness.state).toBe(
      "unavailable"
    )

    // Concurrent refreshes share a single in-flight resolution.
    await Promise.all([run(runtime.refreshEnvironment), run(runtime.refreshEnvironment)])
    expect(resolveCalls).toBe(1)

    const after = await run(runtime.discoverHarnesses)
    expect(after.find((harness) => harness.id === "claude-code")?.readiness).toEqual({
      state: "ready"
    })

    // A later refresh starts a fresh resolution (the shared promise clears).
    await run(runtime.refreshEnvironment)
    expect(resolveCalls).toBe(2)
  })

  it("treats refreshEnvironment as a no-op without a resolveEnv", async () => {
    const runtime = makeAgentRuntime({ env: { PATH: "/fixed" } })
    await expect(run(runtime.refreshEnvironment)).resolves.toBeUndefined()
  })

  it("merges injected extra harnesses and tags them as custom", async () => {
    const runtime = makeAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: (name) => name === "my-agent",
      locateExecutable: () => undefined,
      extraHarnesses: [
        {
          detectBinaries: ["my-agent"],
          id: "my-agent",
          launch: { args: ["acp"], command: "my-agent", kind: "executable" },
          name: "My Agent",
          provider: "acp",
          symbolName: "terminal"
        }
      ]
    })

    // The effective catalog is builtins + the extra entry, and is exposed on
    // the service for consumers (harness auth, lifecycle).
    expect(runtime.catalog).toHaveLength(harnessCatalog.length + 1)
    expect(runtime.catalog.find((definition) => definition.id === "my-agent")?.name).toBe(
      "My Agent"
    )

    const harnesses = await run(runtime.discoverHarnesses)
    const custom = harnesses.find((harness) => harness.id === "my-agent")
    expect(custom).toMatchObject({
      name: "My Agent",
      launchKind: "executable",
      source: "custom",
      readiness: { state: "ready" }
    })
    // Builtins keep their registry source.
    expect(harnesses.find((harness) => harness.id === "codex")?.source).toBe("registry")
  })

  it("drops extra harnesses whose id collides with a builtin", async () => {
    const runtime = makeAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: () => false,
      locateExecutable: () => undefined,
      extraHarnesses: [
        {
          detectBinaries: ["fake-codex"],
          id: "codex",
          launch: { args: [], command: "fake-codex", kind: "executable" },
          name: "Fake Codex",
          provider: "acp",
          symbolName: "terminal"
        }
      ]
    })

    expect(runtime.catalog).toHaveLength(harnessCatalog.length)
    const harnesses = await run(runtime.discoverHarnesses)
    const codex = harnesses.find((harness) => harness.id === "codex")
    expect(codex?.name).toBe("Codex")
    expect(codex?.source).toBe("registry")
  })

  it("keeps the builtin catalog identity when no extras are injected", () => {
    const runtime = makeAgentRuntime({ env: { PATH: "/bin" } })
    expect(runtime.catalog).toBe(harnessCatalog)
  })

  it("swaps custom entries live via setExtraHarnesses", async () => {
    const runtime = makeAgentRuntime({
      env: { PATH: "/bin" },
      executableExists: () => false,
      locateExecutable: () => undefined
    })
    expect(runtime.catalog).toBe(harnessCatalog)

    runtime.setExtraHarnesses([
      {
        detectBinaries: ["late-agent"],
        id: "late-agent",
        launch: { args: ["acp"], command: "late-agent", kind: "executable" },
        name: "Late Agent",
        provider: "acp",
        symbolName: "terminal"
      }
    ])
    expect(runtime.catalog).toHaveLength(harnessCatalog.length + 1)
    const harnesses = await run(runtime.discoverHarnesses)
    expect(harnesses.find((harness) => harness.id === "late-agent")?.source).toBe("custom")

    runtime.setExtraHarnesses([])
    expect(runtime.catalog).toBe(harnessCatalog)
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
    const runtime = makeAgentRuntime({
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
    const runtime = makeAgentRuntime({
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

  it("propagates resolveEnv failures as runtime errors and recovers", async () => {
    let attempts = 0
    const runtime = makeAgentRuntime({
      env: { PATH: "/before" },
      executableExists: (name, env) => name === "claude" && env.PATH === "/after",
      resolveEnv: () => {
        attempts += 1
        return attempts === 1
          ? Promise.reject(new Error("shell exploded"))
          : Promise.resolve({ PATH: "/after" })
      }
    })

    await expect(run(runtime.refreshEnvironment)).rejects.toMatchObject({
      operation: "refreshEnvironment"
    })
    // The failed in-flight promise clears; the next refresh succeeds.
    await run(runtime.refreshEnvironment)
    const harnesses = await run(runtime.discoverHarnesses)
    expect(harnesses.find((harness) => harness.id === "claude-code")?.readiness.state).toBe("ready")
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
    const runtime = makeAgentRuntime({
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
    const runtime = makeAgentRuntime({
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
    const runtime = makeAgentRuntime({
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
    const runtime = makeAgentRuntime({
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
    expect(connector.connections[0]?.closeCount).toBe(0)

    await run(runtime.closeAgentSession(sessionId))
    expect(connector.connections[0]?.closeCount).toBe(1)
    await expect(run(runtime.prompt(sessionId, "hello"))).rejects.toMatchObject({
      operation: "sessionFor"
    })
  })

  it("falls back to executable names when PATH lookup is delegated", async () => {
    const connector = makeConnector()
    const runtime = makeAgentRuntime({
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
    const runtime = makeAgentRuntime({
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

  it("constructs the Effect service layer and handles missing PATH", async () => {
    await expect(run(makeAgentRuntime().discoverHarnesses)).resolves.toEqual(expect.any(Array))

    // locateExecutable is pinned to "nothing found": the default locator also
    // probes absolute fallbackPaths (e.g. /Applications/Codex.app), which
    // would make this machine-dependent.
    const layeredHarnesses = await run(
      Effect.gen(function* () {
        const runtime = yield* AgentRuntime
        return yield* runtime.discoverHarnesses
      }).pipe(Effect.provide(AgentRuntime.layer({ env: {}, locateExecutable: () => undefined })))
    )
    expect(layeredHarnesses.every((harness) => harness.readiness.state === "unavailable")).toBe(
      true
    )

    const runtime = makeAgentRuntime({ env: {}, locateExecutable: () => undefined })
    expect((await run(runtime.discoverHarnesses))[0]?.readiness.detail).toBe(
      "CLI not found on PATH"
    )
  })

  it("checks both ChatGPT.app and Codex.app for the bundled Codex CLI", () => {
    const codex = harnessCatalog.find((harness) => harness.id === "codex")

    expect(codex?.fallbackPaths).toEqual(
      expect.arrayContaining([
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "~/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "~/Applications/Codex.app/Contents/Resources/codex"
      ])
    )
  })

  it("locates absolute and ~-prefixed fallback candidates directly", () => {
    const home = mkdtempSync(join(tmpdir(), "codevisor-locate-"))
    const bundled = join(home, "Applications", "Codex.app", "Contents", "Resources")
    mkdirSync(bundled, { recursive: true })
    const binary = join(bundled, "codex")
    writeFileSync(binary, "#!/bin/sh\n", { mode: 0o755 })
    try {
      // Absolute candidates skip PATH entirely.
      expect(locateExecutableOnPath(binary, {})).toBe(binary)
      expect(locateExecutableOnPath(join(home, "missing"), {})).toBeUndefined()
      // `~/` expands via env.HOME; without a HOME there is nothing to probe.
      expect(
        locateExecutableOnPath("~/Applications/Codex.app/Contents/Resources/codex", {
          HOME: home
        })
      ).toBe(binary)
      expect(
        locateExecutableOnPath("~/Applications/Codex.app/Contents/Resources/codex", {})
      ).toBeUndefined()
      // Plain names still walk PATH — and tolerate an absent PATH.
      expect(locateExecutableOnPath("codex", { PATH: bundled })).toBe(binary)
      expect(locateExecutableOnPath("codex", {})).toBeUndefined()
    } finally {
      rmSync(home, { force: true, recursive: true })
    }
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

    expect(events).toEqual([conversationEvent(sessionId, "assistant", "background task finished")])
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
  })

  it("fails goal calls on harnesses without goal support", async () => {
    const connector = makeConnector()
    const runtime = makeAgentRuntime({
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
            setConfigOption: () => Effect.void,
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
    const runtime = makeAgentRuntime({
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

  it("registers custom providers and drops events for unknown sessions", async () => {
    const events: Array<RuntimeEvent> = []
    let capturedEmit: RuntimeEmit | undefined
    const handle = {
      cancel: Effect.void,
      close: Effect.void,
      prompt: () => Effect.succeed({ stopReason: "end_turn" }),
      setConfigOption: () => Effect.void,
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
    const runtime = makeAgentRuntime({
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

  it("recognizes pi-acp startup info without matching ordinary agent output", () => {
    const startupInfo = "pi v0.80.9\n\nSkills\n\n- /tmp/SKILL.md\n"
    const response = {
      _meta: { piAcp: { startupInfo } },
      sessionId: "pi-session-1"
    }
    const startupNotification = {
      sessionId: "pi-session-1",
      update: {
        content: { text: startupInfo, type: "text" },
        sessionUpdate: "agent_message_chunk"
      }
    } as never
    const ordinaryNotification = {
      sessionId: "pi-session-1",
      update: {
        content: { text: "Here is the answer.", type: "text" },
        sessionUpdate: "agent_message_chunk"
      }
    } as never

    expect(extractPiStartupInfo(response)).toBe(startupInfo)
    expect(isPiStartupInfoNotification(startupNotification, startupInfo)).toBe(true)
    expect(isPiStartupInfoNotification(ordinaryNotification, startupInfo)).toBe(false)
    expect(extractPiStartupInfo({ _meta: { piAcp: { startupInfo: null } } })).toBeUndefined()
  })

  it("recovers Pi provider errors that pi-acp reports as empty turns", () => {
    const providerError = JSON.stringify({
      type: "message",
      message: {
        role: "assistant",
        content: [],
        stopReason: "error",
        errorMessage: '400 {"type":"error","error":{"message":"Add extra usage and try again."}}'
      }
    })
    const successfulAssistant = JSON.stringify({
      type: "message",
      message: { role: "assistant", content: [{ type: "text", text: "Done" }], stopReason: "stop" }
    })

    expect(piAssistantErrorFromSessionJsonl(`{"type":"session"}\n${providerError}\n`)).toBe(
      "Add extra usage and try again."
    )
    expect(
      piAssistantErrorFromSessionJsonl(`{"type":"session"}\n${successfulAssistant}\n`)
    ).toBeUndefined()
    expect(
      piAssistantErrorFromSessionJsonl('{"type":"message","message":{"role":"user"}}\n')
    ).toBeUndefined()
  })

  it("removes redundant prefixes from ACP reasoning choices only", () => {
    const options = normalizeAcpConfigOptions([
      {
        category: "thought_level",
        currentValue: "low",
        id: "thinking_level",
        name: "Thinking",
        options: [
          { name: "Thinking: off", value: "off" },
          { name: "Thinking: low", value: "low" },
          { name: "Reasoning: high", value: "high" }
        ],
        type: "select"
      },
      {
        category: "model",
        currentValue: "thinking-model",
        id: "model",
        name: "Model",
        options: [{ name: "Thinking: model", value: "thinking-model" }],
        type: "select"
      }
    ] as never)

    expect(options[0]?.options.map((option) => option.name)).toEqual(["off", "low", "high"])
    expect(options[1]?.options.map((option) => option.name)).toEqual(["Thinking: model"])
  })

  it("maps ACP permission requests onto questions and answers back onto option ids", () => {
    const params = {
      options: [
        { kind: "allow_once", name: "Yes, and manually approve edits", optionId: "default" },
        { kind: "reject_once", name: "No, keep planning", optionId: "plan" }
      ],
      sessionId: "session-1",
      toolCall: {
        content: [{ content: { text: "# The Plan\n\n1. Do it", type: "text" }, type: "content" }],
        kind: "switch_mode",
        title: "Ready to code?",
        toolCallId: "exit-plan-1"
      }
    }
    const question = acpPermissionQuestion(params)
    expect(question?.sessionId).toBe("session-1")
    expect(question?.planDocument).toBe("# The Plan\n\n1. Do it")
    expect(question?.spec).toEqual({
      allowsOther: false,
      id: "permission",
      options: [{ label: "Yes, and manually approve edits" }, { label: "No, keep planning" }],
      question: "Ready to code?"
    })

    const optionIds = question!.optionIds
    expect(
      acpPermissionOutcome(optionIds, {
        answers: { permission: { answers: ["No, keep planning"] } },
        outcome: "answered"
      })
    ).toEqual({ outcome: { optionId: "plan", outcome: "selected" } })
    expect(acpPermissionOutcome(optionIds, { outcome: "cancelled" })).toEqual({
      outcome: { outcome: "cancelled" }
    })
    // Unknown labels degrade to cancelled rather than guessing.
    expect(
      acpPermissionOutcome(optionIds, {
        answers: { permission: { answers: ["Nonsense"] } },
        outcome: "answered"
      })
    ).toEqual({ outcome: { outcome: "cancelled" } })

    // Requests without options (or malformed ones) auto-cancel.
    expect(acpPermissionQuestion({ options: [], sessionId: "s" })).toBeUndefined()
    expect(acpPermissionQuestion("nope")).toBeUndefined()
    // Non-plan tool calls carry no plan document and fall back to a generic
    // question when untitled.
    const generic = acpPermissionQuestion({
      options: [{ kind: "allow_once", name: "Allow", optionId: "ok" }],
      sessionId: "s",
      toolCall: { kind: "execute", toolCallId: "t1" }
    })
    expect(generic?.planDocument).toBeUndefined()
    expect(generic?.spec.question).toBe("Allow the agent to proceed?")
  })

  it("maps agent-defined ACP modes onto the canonical vocabulary heuristically", () => {
    const state = normalizeModeState({
      currentModeId: "default",
      availableModes: [
        { id: "default", name: "Default" },
        { id: "plan", name: "Plan mode", description: "think first" },
        { id: "readOnly", name: "Read Only" },
        { id: "acceptEdits", name: "Accept Edits" },
        { id: "yolo", name: "YOLO" },
        { id: "goal", name: "Goal mode" }
      ]
    })
    expect(state.availableModes.map((mode) => mode.canonicalId)).toEqual([
      "ask",
      "plan",
      "readOnly",
      "autoEdit",
      "fullAccess",
      undefined
    ])
    // Descriptions still pass through untouched.
    expect(state.availableModes[1]?.description).toBe("think first")
  })
})

describe("acp model-selection extension", () => {
  it("distinguishes a native model option from the optional model extension", () => {
    expect(
      acpConfigOptionIds({
        configOptions: [
          { id: "model", type: "select" },
          { id: "thought_level", type: "select" }
        ]
      })
    ).toEqual(new Set(["model", "thought_level"]))
    expect(acpConfigOptionIds({ models: { currentModelId: "gpt" } })).toEqual(new Set())
    expect(usesAcpModelSelectionExtension("model", new Set(["model"]))).toBe(false)
    expect(usesAcpModelSelectionExtension("model", new Set(["thought_level"]))).toBe(true)
    expect(usesAcpModelSelectionExtension("thought_level", undefined)).toBe(false)
  })

  type ModelSetter = Parameters<typeof applyAcpModelSelection>[0]
  const fakeConnection = (
    request: (method: string, params: unknown) => Promise<unknown>
  ): ModelSetter => ({ agent: { request } }) as unknown as ModelSetter

  it("reads the models extension off a session/new response into a model picker", () => {
    const state = extractAcpModelState({
      sessionId: "s-1",
      models: {
        currentModelId: "grok-4.5",
        availableModels: [
          { modelId: "grok-4.5", name: "Grok 4.5", description: "frontier" },
          { modelId: "grok-composer-2.5-fast", name: "Composer 2.5" }
        ]
      }
    })
    expect(state).toEqual({
      currentModelId: "grok-4.5",
      availableModels: [
        { modelId: "grok-4.5", name: "Grok 4.5", description: "frontier" },
        { modelId: "grok-composer-2.5-fast", name: "Composer 2.5" }
      ]
    })
    expect(
      acpModelConfigOption({
        currentModelId: "grok-4.5",
        availableModels: [
          { modelId: "grok-4.5", name: "Grok 4.5", description: "frontier" },
          { modelId: "grok-composer-2.5-fast", name: "Composer 2.5" }
        ]
      })
    ).toEqual({
      category: "model",
      currentValue: "grok-4.5",
      id: acpModelConfigId,
      name: "Model",
      options: [
        { value: "grok-4.5", name: "Grok 4.5", description: "frontier" },
        { value: "grok-composer-2.5-fast", name: "Composer 2.5" }
      ]
    })
  })

  it("ignores responses without a well-formed models extension", () => {
    expect(extractAcpModelState(undefined)).toBeUndefined()
    expect(extractAcpModelState({})).toBeUndefined()
    expect(extractAcpModelState({ models: null })).toBeUndefined()
    expect(
      extractAcpModelState({ models: { currentModelId: 1, availableModels: [] } })
    ).toBeUndefined()
    expect(
      extractAcpModelState({ models: { currentModelId: "m", availableModels: "nope" } })
    ).toBeUndefined()
    // Entries without a string modelId are dropped; if none remain, treat the
    // extension as absent rather than surfacing an empty picker.
    expect(
      extractAcpModelState({
        models: { currentModelId: "m", availableModels: [{ name: "no id" }, 7] }
      })
    ).toBeUndefined()
  })

  it("falls back to the model id when an entry omits a display name", () => {
    expect(
      extractAcpModelState({
        models: { currentModelId: "m1", availableModels: [{ modelId: "m1" }] }
      })
    ).toEqual({ currentModelId: "m1", availableModels: [{ modelId: "m1", name: "m1" }] })
  })

  it("applies a model change via session/set_model and rebuilds the picker", async () => {
    const calls: Array<{ readonly method: string; readonly params: unknown }> = []
    const connection = fakeConnection(async (method, params) => {
      calls.push({ method, params })
      return { _meta: { model: { Ok: "grok-composer-2.5-fast" } } }
    })
    const states = new Map([
      [
        "s-1",
        {
          currentModelId: "grok-4.5",
          availableModels: [
            { modelId: "grok-4.5", name: "Grok 4.5" },
            { modelId: "grok-composer-2.5-fast", name: "Composer 2.5" }
          ]
        }
      ]
    ])
    const options = await applyAcpModelSelection(
      connection,
      states,
      "s-1",
      "grok-composer-2.5-fast"
    )
    expect(calls).toEqual([
      {
        method: "session/set_model",
        params: { modelId: "grok-composer-2.5-fast", sessionId: "s-1" }
      }
    ])
    expect(options).toEqual([
      {
        category: "model",
        currentValue: "grok-composer-2.5-fast",
        id: acpModelConfigId,
        name: "Model",
        options: [
          { value: "grok-4.5", name: "Grok 4.5" },
          { value: "grok-composer-2.5-fast", name: "Composer 2.5" }
        ]
      }
    ])
    expect(states.get("s-1")?.currentModelId).toBe("grok-composer-2.5-fast")
  })

  it("falls back to a single-entry picker for a resumed session with no cached models", async () => {
    const connection = fakeConnection(async () => ({ _meta: { model: { Ok: "m2" } } }))
    const options = await applyAcpModelSelection(connection, new Map(), "s-2", "m2")
    expect(options).toEqual([
      {
        category: "model",
        currentValue: "m2",
        id: acpModelConfigId,
        name: "Model",
        options: [{ value: "m2", name: "m2" }]
      }
    ])
  })

  it("uses the requested model id when the setter omits an Ok value", async () => {
    const connection = fakeConnection(async () => ({}))
    const options = await applyAcpModelSelection(connection, new Map(), "s-3", "m3")
    expect(options[0]?.currentValue).toBe("m3")
  })

  it("throws when session/set_model reports a string error", async () => {
    const connection = fakeConnection(async () => ({ _meta: { model: { Err: "unknown model" } } }))
    await expect(applyAcpModelSelection(connection, new Map(), "s-4", "bogus")).rejects.toThrow(
      "session/set_model failed: unknown model"
    )
  })

  it("stringifies non-string set_model errors", async () => {
    const connection = fakeConnection(async () => ({ _meta: { model: { Err: { code: 42 } } } }))
    await expect(applyAcpModelSelection(connection, new Map(), "s-5", "bogus")).rejects.toThrow(
      'session/set_model failed: {"code":42}'
    )
  })

  it("maps Grok model metadata into a server-defined reasoning picker", async () => {
    const state = extractAcpModelState({
      _meta: {
        "x.ai/sessionConfig": {
          options: [{ category: "mode", id: "deep", label: "Deep", selected: true }]
        }
      },
      models: {
        currentModelId: "grok-4.5",
        availableModels: [
          {
            modelId: "grok-4.5",
            name: "Grok 4.5",
            _meta: {
              supportsReasoningEffort: true,
              reasoningEffort: "high",
              reasoningEfforts: [
                { value: "low", label: "Low Effort" },
                {
                  id: "deep",
                  value: "xhigh",
                  label: "Deep",
                  description: "Use maximum reasoning"
                }
              ]
            }
          }
        ]
      }
    })
    expect(state).toBeDefined()
    expect(acpReasoningEffortConfigOption(state!)).toEqual({
      category: "thought_level",
      currentValue: "deep",
      id: "reasoning_effort",
      name: "Reasoning",
      options: [
        { value: "low", name: "Low" },
        { value: "deep", name: "Deep", description: "Use maximum reasoning" }
      ]
    })

    const calls: Array<{ readonly method: string; readonly params: unknown }> = []
    const connection = fakeConnection(async (method, params) => {
      calls.push({ method, params })
      return { _meta: { model: { Ok: "grok-4.5" } } }
    })
    const options = await applyAcpReasoningEffortSelection(
      connection,
      new Map([["s-1", state!]]),
      "s-1",
      "low"
    )
    expect(calls).toEqual([
      {
        method: "session/set_model",
        params: {
          _meta: { reasoningEffort: "low" },
          modelId: "grok-4.5",
          sessionId: "s-1"
        }
      }
    ])
    expect(options[1]?.currentValue).toBe("low")
  })

  it("uses Grok's built-in reasoning levels when the model omits a menu", () => {
    const state = extractAcpModelState({
      models: {
        currentModelId: "grok-4.5",
        availableModels: [
          {
            modelId: "grok-4.5",
            name: "Grok 4.5",
            _meta: { supportsReasoningEffort: true, reasoningEffort: "medium" }
          }
        ]
      }
    })
    const reasoning = acpReasoningEffortConfigOption(state!)
    const values = reasoning?.options.flatMap((option) =>
      "group" in option ? option.options.map((nested) => nested.value) : [option.value]
    )
    expect(values).toEqual(["minimal", "low", "medium", "high", "xhigh"])
    expect(acpReasoningEffortConfigOption(state!)?.currentValue).toBe("medium")
  })
})

describe("Grok ACP compatibility", () => {
  it("advertises the modes Grok implements but does not report", () => {
    expect(grokModeState.currentModeId).toBe("default")
    expect(grokModeState.availableModes.map((mode) => [mode.id, mode.canonicalId])).toEqual([
      ["default", "fullAccess"],
      ["plan", "plan"],
      ["ask", "ask"]
    ])
  })

  it("maps Grok plan approval responses and plan markdown", () => {
    const mapped = grokPlanApprovalQuestion({
      sessionId: "s-1",
      toolCallId: "tool-1",
      planContent: "# Plan\n\nShip it."
    })
    expect(mapped?.planDocument).toBe("# Plan\n\nShip it.")
    expect(mapped?.questions[0]?.options.map((option) => option.label)).toEqual([
      "Implement plan",
      "Keep planning",
      "Abandon plan"
    ])
    expect(
      mapped?.responseFor({
        outcome: "answered",
        answers: { grok_exit_plan_mode: { answers: ["Implement plan"] } }
      })
    ).toEqual({ outcome: "approved" })
    expect(
      mapped?.responseFor({
        outcome: "answered",
        answers: {
          grok_exit_plan_mode: { answers: ["Keep planning"], note: "Add rollback steps" }
        }
      })
    ).toEqual({ outcome: "cancelled", feedback: "Add rollback steps" })
    expect(
      mapped?.responseFor({
        outcome: "answered",
        answers: { grok_exit_plan_mode: { answers: ["Abandon plan"] } }
      })
    ).toEqual({ outcome: "abandoned" })
  })

  it("maps Grok's blocking questionnaire into Codevisor answers", () => {
    const mapped = grokAskUserQuestion({
      sessionId: "s-1",
      toolCallId: "tool-1",
      mode: "plan",
      questions: [
        {
          question: "Which database?",
          options: [
            {
              label: "SQLite",
              description: "Keep it local",
              preview: "schema preview"
            },
            { label: "Postgres", description: "Use a server" }
          ]
        },
        {
          question: "Anything else?",
          options: [],
          multiSelect: false
        }
      ]
    })
    expect(mapped?.questions).toEqual([
      {
        id: "Which database?",
        question: "Which database?",
        options: [
          { label: "SQLite", description: "Keep it local" },
          { label: "Postgres", description: "Use a server" }
        ],
        allowsOther: true
      },
      {
        id: "Anything else?",
        question: "Anything else?",
        options: [],
        allowsOther: true
      }
    ])
    expect(
      mapped?.responseFor({
        outcome: "answered",
        answers: {
          "Which database?": { answers: ["SQLite"] },
          "Anything else?": { answers: [], note: "Add backups" }
        }
      })
    ).toEqual({
      outcome: "accepted",
      answers: {
        "Which database?": ["SQLite"],
        "Anything else?": ["Other"]
      },
      annotations: {
        "Which database?": { preview: "schema preview" },
        "Anything else?": { notes: "Add backups" }
      }
    })
  })

  it("maps Grok goal progress and preserves the goal creation time", () => {
    const active = grokGoalNotification(
      {
        sessionId: "s-1",
        update: {
          sessionUpdate: "goal_updated",
          objective: "Ship goal mode",
          status: "active",
          verifying_completion: true,
          token_budget: 20_000,
          tokens_used: 1_250,
          elapsed_ms: 2_500
        }
      },
      undefined,
      "2026-07-16T12:00:00.000Z"
    )
    expect(active?.goal).toEqual({
      objective: "Ship goal mode",
      status: "active",
      activity: "verifying",
      tokenBudget: 20_000,
      tokensUsed: 1_250,
      timeUsedSeconds: 2.5,
      createdAt: "2026-07-16T12:00:00.000Z",
      updatedAt: "2026-07-16T12:00:00.000Z"
    })
    const paused = grokGoalNotification(
      {
        method: "x.ai/session_notification",
        params: {
          sessionId: "s-1",
          update: {
            sessionUpdate: "goal_updated",
            objective: "Ship goal mode",
            status: "back_off_paused",
            tokens_used: 2_000,
            elapsed_ms: 4_000
          }
        }
      },
      () => active?.goal,
      "2026-07-16T12:01:00.000Z"
    )
    expect(paused?.goal?.status).toBe("paused")
    expect(paused?.goal?.createdAt).toBe("2026-07-16T12:00:00.000Z")
    expect(paused?.event.payload).toEqual({ goal: paused?.goal })
  })

  it("maps Grok goal clearing onto the shared cleared event", () => {
    const cleared = grokGoalNotification({
      sessionId: "s-1",
      update: { sessionUpdate: "goal_updated", status: "cleared" }
    })
    expect(cleared).toEqual({
      sessionId: "s-1",
      goal: undefined,
      event: {
        kind: "session.updated",
        subjectId: "s-1",
        payload: { goalCleared: true }
      }
    })
  })
})

describe("prompt attachments", () => {
  const image: PromptAttachmentInput = {
    data: Buffer.from("img"),
    kind: "image",
    mimeType: "image/png",
    name: "shot.png",
    path: "/tmp/att/shot.png"
  }
  const file: PromptAttachmentInput = {
    data: Buffer.from("notes"),
    kind: "file",
    mimeType: "text/plain",
    name: "notes.txt",
    path: "/tmp/att/notes.txt"
  }

  it("normalizes prompt input from strings and structured input", () => {
    expect(normalizePromptInput("hello")).toEqual({ text: "hello" })
    const input = { attachments: [image], text: "hi" }
    expect(normalizePromptInput(input)).toBe(input)
  })

  it("appends path notes for attachments, skipping empty text", () => {
    expect(withAttachmentNotes("hello", [])).toBe("hello")
    expect(withAttachmentNotes("hello", [file])).toBe(
      "hello\n\n[Attached file: /tmp/att/notes.txt (notes.txt, text/plain)]"
    )
    expect(withAttachmentNotes("", [file])).toBe(
      "[Attached file: /tmp/att/notes.txt (notes.txt, text/plain)]"
    )
  })

  it("builds ACP prompt blocks: resource_link for every file, inline images when supported", () => {
    expect(acpPrompt({ attachments: [image, file], text: "look" }, { image: true })).toEqual([
      { text: "look", type: "text" },
      {
        mimeType: "image/png",
        name: "shot.png",
        size: 3,
        type: "resource_link",
        uri: "file:///tmp/att/shot.png"
      },
      { data: Buffer.from("img").toString("base64"), mimeType: "image/png", type: "image" },
      {
        mimeType: "text/plain",
        name: "notes.txt",
        size: 5,
        type: "resource_link",
        uri: "file:///tmp/att/notes.txt"
      }
    ])
    // No image capability: the image still arrives as a readable resource_link.
    expect(acpPrompt({ attachments: [image], text: "look" }, {})).toEqual([
      { text: "look", type: "text" },
      {
        mimeType: "image/png",
        name: "shot.png",
        size: 3,
        type: "resource_link",
        uri: "file:///tmp/att/shot.png"
      }
    ])
    // Image-only prompts drop the empty text block.
    expect(acpPrompt({ attachments: [image], text: "" }, { image: true })).toEqual([
      {
        mimeType: "image/png",
        name: "shot.png",
        size: 3,
        type: "resource_link",
        uri: "file:///tmp/att/shot.png"
      },
      { data: Buffer.from("img").toString("base64"), mimeType: "image/png", type: "image" }
    ])
    expect(acpPrompt({ text: "plain" }, { image: true })).toEqual([{ text: "plain", type: "text" }])
  })
})

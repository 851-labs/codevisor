import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { afterEach, describe, expect, it, vi } from "vitest"

import { makeClaudeProvider } from "./provider.js"
import {
  definition,
  environment,
  FakeQuery,
  initMessage,
  makeProvider,
  payloadOf,
  resultMessage,
  run,
  streamEvent
} from "./test-support.js"

const STREAM_RECOVERY_BACKOFF_MS = 1_000

describe("ClaudeProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("prefers SDK session titles while retaining scanner fallbacks", async () => {
    const provider = makeClaudeProvider(environment, {
      listSdkSessions: async () => [
        {
          customTitle: "Renamed by Claude",
          lastModified: 0,
          sessionId: "one",
          summary: "Generated"
        },
        { lastModified: 0, sessionId: "two", summary: "" }
      ],
      scanAgentSessions: async () => [
        { cwd: "/one", sessionId: "one", title: "First prompt one" },
        { cwd: "/two", sessionId: "two", title: "First prompt two" }
      ]
    })

    await expect(provider.listAgentSessions!(definition)).resolves.toEqual([
      { cwd: "/one", sessionId: "one", title: "Renamed by Claude" },
      { cwd: "/two", sessionId: "two", title: "First prompt two" }
    ])
  })

  it("skips the SDK title lookup when titles are not wanted", async () => {
    const provider = makeClaudeProvider(environment, {
      listSdkSessions: async () => {
        throw new Error("title lookup should be skipped")
      },
      scanAgentSessions: async () => [{ cwd: "/one", sessionId: "one", title: "First prompt" }]
    })

    await expect(
      provider.listAgentSessions!(definition, undefined, { titles: false })
    ).resolves.toEqual([{ cwd: "/one", sessionId: "one", title: "First prompt" }])
  })

  it("creates a session against the located binary and reports models/modes", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }

    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage())
    const created = await createPromise

    expect(created.metadata.sessionId).toBeTruthy()
    expect(fake.options?.extraArgs?.["session-id"]).toBe(created.metadata.sessionId)
    expect(fake.options?.systemPrompt).toEqual({ type: "preset", preset: "claude_code" })
    expect(created.metadata.modes?.currentModeId).toBe("bypassPermissions")
    expect(fake.options?.permissionMode).toBe("bypassPermissions")
    expect(created.metadata.modes?.availableModes.find((mode) => mode.id === "default")?.name).toBe(
      "Always Ask"
    )
    expect(created.metadata.modes?.availableModes.map((mode) => mode.canonicalId)).toEqual([
      "ask",
      "autoEdit",
      "plan",
      "fullAccess"
    ])
    expect(created.metadata.modes?.availableModes.every((mode) => mode.description)).toBe(true)
    expect(created.metadata.configOptions[0]?.id).toBe("model")
    expect(created.metadata.configOptions[0]?.currentValue).toBe("claude-fable-5")
    const effort = created.metadata.configOptions.find((option) => option.id === "effort")
    expect(effort?.currentValue).toBe("high")
    expect(effort?.options.map((option) => ("value" in option ? option.value : ""))).toEqual([
      "low",
      "medium",
      "high",
      "xhigh"
    ])
    expect(fake.options?.pathToClaudeCodeExecutable).toBe("/bin/claude")
    expect(fake.options?.includePartialMessages).toBe(true)
    expect(fake.options?.resume).toBeUndefined()
  })

  it("rejects claude binaries older than the version floor", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake, async () => "1.0.44")
    await expect(
      run(provider.createSession(definition, "/tmp", async () => undefined))
    ).rejects.toThrow("older than the required")
  })

  it("turns off Claude's own browser and desktop tools whenever Codevisor's are attached", async () => {
    vi.useFakeTimers()
    const gateway = { bearerToken: "secret", name: "codevisor", url: "http://127.0.0.1:1/mcp" }
    const fresh = new FakeQuery()
    const recovered = new FakeQuery()
    fresh.successors.push(recovered)
    const started = run(
      makeProvider(fresh).createSession(definition, "/tmp", async () => {}, undefined, gateway)
    )
    fresh.push(initMessage())
    const created = await started
    expect(fresh.options?.extraArgs).toEqual({
      "no-chrome": null,
      "session-id": created.metadata.sessionId
    })
    const skillsOff = {
      "built-in-browser": "off",
      "chrome-browser": "off",
      "computer-use": "off"
    }
    expect(fresh.options?.settings).toEqual({ skillOverrides: skillsOff })

    const prompt = run(created.handle.prompt("do work"))
    await fresh.nextPrompt()
    fresh.finish()
    await vi.advanceTimersByTimeAsync(STREAM_RECOVERY_BACKOFF_MS)
    await recovered.nextPrompt()
    expect(recovered.options?.extraArgs).toEqual({ "no-chrome": null })
    expect(recovered.options?.settings).toMatchObject({ skillOverrides: skillsOff })
    expect(recovered.options?.systemPrompt).toEqual({ type: "preset", preset: "claude_code" })
    recovered.push(resultMessage())
    await prompt

    const resumed = new FakeQuery()
    const resuming = run(
      makeProvider(resumed).loadSession(
        definition,
        "previous-session",
        "/tmp",
        async () => undefined,
        undefined,
        gateway
      )
    )
    await resuming
    expect(resumed.options).toMatchObject({
      extraArgs: { "no-chrome": null },
      resume: "previous-session",
      settings: { skillOverrides: skillsOff }
    })
  })

  it("resumes an in-flight turn on a fresh query when the SDK stream dies", async () => {
    vi.useFakeTimers()
    const fake = new FakeQuery()
    const resumed = new FakeQuery()
    fake.successors.push(resumed)
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(
      provider.createSession(definition, "/tmp", emit, undefined, undefined, {
        configSelections: { model: "claude-opus-4-8" }
      })
    )
    fake.push(initMessage("sdk-session-1", "claude-opus-4-8"))
    const created = await createPromise
    await run(created.handle.setConfigOption("model", "claude-fable-5"))
    await run(created.handle.setConfigOption("effort", "xhigh"))

    const promptPromise = run(created.handle.prompt("do work"))
    await fake.nextPrompt()
    fake.push(
      streamEvent({
        content_block: { id: "tool-x", name: "Bash", type: "tool_use" },
        index: 0,
        type: "content_block_start"
      })
    )
    await fake.drain()

    fake.finish()
    await vi.advanceTimersByTimeAsync(STREAM_RECOVERY_BACKOFF_MS - 1)
    expect(resumed.promptInput).toBeUndefined()
    await vi.advanceTimersByTimeAsync(1)
    await resumed.nextPrompt()
    expect(resumed.options?.resume).toBe(fake.options?.extraArgs?.["session-id"])
    expect(resumed.options?.resume).toBeTypeOf("string")
    expect(resumed.options?.extraArgs).toBeUndefined()
    expect(resumed.options).toMatchObject({
      model: "claude-fable-5",
      settings: { effortLevel: "xhigh", fastMode: false }
    })
    expect(resumed.userMessages).toHaveLength(1)
    expect(resumed.userMessages[0]?.message.content).toContain("interrupted and restarted")
    expect(events.map(payloadOf)).not.toContainEqual(
      expect.objectContaining({ turnState: "ended" })
    )

    resumed.push(resultMessage())
    const result = await promptPromise
    expect(result.stopReason).toBe("end_turn")
    const ended = events.map(payloadOf).filter((payload) => payload.turnState === "ended")
    expect(ended).toHaveLength(1)
    expect(ended[0]).not.toHaveProperty("stopDetail")
  })

  it("ends the turn with a retryable reason once stream resumptions are exhausted", async () => {
    vi.useFakeTimers()
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("do work"))
    await fake.nextPrompt()
    fake.push(
      streamEvent({
        content_block: { id: "tool-x", name: "Bash", type: "tool_use" },
        index: 0,
        type: "content_block_start"
      })
    )
    await fake.drain()

    fake.finish()
    let settled = false
    void promptPromise.then(() => {
      settled = true
    })
    await vi.advanceTimersByTimeAsync(3 * STREAM_RECOVERY_BACKOFF_MS - 1)
    expect(settled).toBe(false)
    await vi.advanceTimersByTimeAsync(1)
    const result = await promptPromise
    expect(result.stopReason).toBe("end_turn")

    const payloads = events.map(payloadOf)
    expect(payloads).toContainEqual(
      expect.objectContaining({
        retryable: true,
        stopDetail: "The Claude connection ended unexpectedly.",
        turnState: "ended"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "tool_call_update",
        status: "failed",
        toolCallId: "tool-x"
      })
    )
  })

  it("does not surface an expected SDK abort after the session is retired", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const createPromise = run(
      provider.createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    fake.push(initMessage())
    const created = await createPromise

    await run(created.handle.close)
    fake.fail(new Error("Operation aborted"))
    await fake.drain()

    expect(events.every((event) => event.kind !== "session.error")).toBe(true)
  })

  it("resumes sessions under the requested id", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const loadPromise = run(
      provider.loadSession(
        definition,
        "previous-session",
        "/tmp",
        async () => undefined,
        undefined,
        undefined,
        { configSelections: { effort: "low", model: "claude-opus-4-8" } }
      )
    )
    const loaded = await loadPromise
    expect(loaded.sessionId).toBe("previous-session")
    expect(loaded.metadata?.sessionId).toBe("previous-session")
    expect(fake.options?.resume).toBe("previous-session")
    expect(fake.options?.model).toBe("claude-opus-4-8")
    expect(loaded.metadata?.configOptions).toContainEqual(
      expect.objectContaining({ currentValue: "claude-opus-4-8", id: "model" })
    )
  })

  it("reports readiness from binary presence", () => {
    const provider = makeProvider(new FakeQuery())
    expect(provider.readiness(definition)).toEqual({ state: "ready" })
    const missing = makeClaudeProvider({
      env: {},
      executableExists: () => false,
      locateExecutable: () => undefined
    })
    expect(missing.readiness(definition)).toEqual({
      detail: "CLI not found on PATH",
      state: "unavailable"
    })
  })
})

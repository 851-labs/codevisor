import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { afterEach, describe, expect, it, vi } from "vitest"

import { makeClaudeProvider } from "./claude.js"
import {
  definition,
  environment,
  FakeQuery,
  initMessage,
  makeProvider,
  resultMessage,
  run,
  streamEvent
} from "./test-support.js"

describe("ClaudeProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("prefers SDK session titles while retaining scanner fallbacks", async () => {
    const provider = makeClaudeProvider(environment, {
      listSdkSessions: async () =>
        [
          { customTitle: "Renamed by Claude", sessionId: "one", summary: "Generated" },
          { sessionId: "two", summary: "" }
        ] as never,
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

    // The session id is assigned client-side and handed to the CLI.
    expect(created.metadata.sessionId).toBeTruthy()
    expect(fake.options?.extraArgs?.["session-id"]).toBe(created.metadata.sessionId)
    // Full access is the default posture; the CLI is started in bypass so it
    // matches the advertised mode.
    expect(created.metadata.modes?.currentModeId).toBe("bypassPermissions")
    expect(fake.options?.permissionMode).toBe("bypassPermissions")
    expect(created.metadata.modes?.availableModes.find((mode) => mode.id === "default")?.name).toBe(
      "Always Ask"
    )
    // Permission modes carry the canonical Codevisor vocabulary + descriptions.
    expect(created.metadata.modes?.availableModes.map((mode) => mode.canonicalId)).toEqual([
      "ask",
      "autoEdit",
      "plan",
      "fullAccess"
    ])
    expect(created.metadata.modes?.availableModes.every((mode) => mode.description)).toBe(true)
    expect(created.metadata.configOptions[0]?.id).toBe("model")
    expect(created.metadata.configOptions[0]?.currentValue).toBe("claude-fable-5")
    // No synthetic "Default" entry: the CLI's own default ("high") is shown.
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

  it("resumes an in-flight turn on a fresh query when the SDK stream dies", async () => {
    const fake = new FakeQuery()
    const resumed = new FakeQuery()
    fake.successors.push(resumed)
    const provider = makeProvider(fake, undefined, undefined, { streamRecoveryBackoffMs: 0 })
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

    // The SDK stream ends mid-turn with no `result` (CLI crashed / pipe
    // closed). The turn is NOT ended: the same CLI session is resumed on a
    // fresh query and nudged to continue — invisible to the user.
    fake.finish()
    await resumed.nextPrompt()
    // Resumed by the id the first query was started with, and without the
    // fresh-session `--session-id` flag that would conflict with it.
    expect(resumed.options?.resume).toBe(fake.options?.extraArgs?.["session-id"])
    expect(resumed.options?.resume).toBeTypeOf("string")
    expect(resumed.options?.extraArgs).toBeUndefined()
    // The nudge tells the model its process was interrupted, so it re-runs a
    // cut-off tool call instead of waiting on results that will never come.
    expect(resumed.userMessages).toHaveLength(1)
    expect(String(resumed.userMessages[0]?.message.content)).toContain("interrupted and restarted")
    expect(events.map((event) => event.payload as Record<string, unknown>)).not.toContainEqual(
      expect.objectContaining({ turnState: "ended" })
    )

    // The resumed query finishes the turn normally: one turn, one clean end.
    resumed.push(resultMessage())
    const result = await promptPromise
    expect(result.stopReason).toBe("end_turn")
    const ended = events
      .map((event) => event.payload as Record<string, unknown>)
      .filter((payload) => payload.turnState === "ended")
    expect(ended).toHaveLength(1)
    expect(ended[0]).not.toHaveProperty("stopDetail")
  })

  it("ends the turn with a retryable reason once stream resumptions are exhausted", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake, undefined, undefined, { streamRecoveryBackoffMs: 0 })
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("do work"))
    await fake.nextPrompt()
    // Open a tool call so we can prove it gets settled on the safety-net path.
    fake.push(
      streamEvent({
        content_block: { id: "tool-x", name: "Bash", type: "tool_use" },
        index: 0,
        type: "content_block_start"
      })
    )
    await fake.drain()

    // No successor queries: every resumption gets the same dead stream back,
    // so the bounded recovery gives up and the turn ends visibly.
    fake.finish()
    const result = await promptPromise
    expect(result.stopReason).toBe("end_turn")

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
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
      provider.loadSession(definition, "previous-session", "/tmp", async () => undefined)
    )
    fake.push(initMessage("sdk-session-resumed"))
    const loaded = await loadPromise
    expect(loaded.sessionId).toBe("previous-session")
    expect(loaded.metadata?.sessionId).toBe("previous-session")
    expect(loaded.metadata?.configOptions.length).toBeGreaterThan(0)
    expect(fake.options?.resume).toBe("previous-session")
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

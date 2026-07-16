import type {
  Options as ClaudeOptions,
  SDKMessage,
  SDKUserMessage
} from "@anthropic-ai/claude-agent-sdk"
import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { HarnessDefinition, ProviderEnvironment, RuntimeEvent } from "../types.js"
import {
  type ClaudeProviderConfig,
  claudeUsageLimitsFrom,
  extractAllStringFields,
  extractStringField,
  makeClaudeProvider,
  webSearchSources
} from "./claude.js"

const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

const definition: HarnessDefinition = {
  detectBinaries: ["claude"],
  id: "claude-code",
  name: "Claude Code",
  provider: "claude",
  symbolName: "sparkle"
}

const environment: ProviderEnvironment = {
  env: { PATH: "/bin" },
  executableExists: (name) => name === "claude",
  locateExecutable: (name) => (name === "claude" ? "/bin/claude" : undefined)
}

describe("Claude account usage", () => {
  it("normalizes the SDK's structured plan windows", () => {
    const limits = claudeUsageLimitsFrom({
      session: {
        model_usage: {},
        total_api_duration_ms: 0,
        total_cost_usd: 0,
        total_duration_ms: 0,
        total_lines_added: 0,
        total_lines_removed: 0
      },
      subscription_type: "max",
      rate_limits_available: true,
      rate_limits: {
        five_hour: { utilization: 31, resets_at: "2026-07-15T20:00:00Z" },
        seven_day: { utilization: 64, resets_at: "2026-07-20T00:00:00Z" },
        seven_day_opus: null,
        seven_day_sonnet: null
      },
      behaviors: null
    })

    expect(limits).toMatchObject({
      state: "available",
      plan: "max",
      windows: [
        { id: "five-hour", label: "5-hour limit", usedPercent: 31 },
        { id: "seven-day", label: "Weekly limit", usedPercent: 64 }
      ]
    })
  })
})

/// A controllable SDK Query: tests push scripted SDKMessages and observe the
/// streaming-input prompt the provider writes into.
class FakeQuery {
  private buffer: Array<SDKMessage> = []
  private waiting: ((result: IteratorResult<SDKMessage>) => void) | undefined
  private ended = false
  readonly interrupts: Array<number> = []
  readonly permissionModes: Array<string> = []
  readonly models: Array<string | undefined> = []
  readonly flagSettings: Array<Record<string, unknown>> = []
  promptInput: AsyncIterable<SDKUserMessage> | undefined
  options: ClaudeOptions | undefined
  readonly userMessages: Array<SDKUserMessage> = []

  push(message: SDKMessage): void {
    const waiting = this.waiting
    if (waiting !== undefined) {
      this.waiting = undefined
      waiting({ done: false, value: message })
      return
    }
    this.buffer.push(message)
  }

  finish(): void {
    this.ended = true
    this.waiting?.({ done: true, value: undefined })
    this.waiting = undefined
  }

  async interrupt(): Promise<void> {
    this.interrupts.push(Date.now())
  }

  async setPermissionMode(mode: string): Promise<void> {
    this.permissionModes.push(mode)
  }

  async setModel(model?: string): Promise<void> {
    this.models.push(model)
  }

  async applyFlagSettings(settings: Record<string, unknown>): Promise<void> {
    this.flagSettings.push(settings)
  }

  async supportedModels(): Promise<
    Array<{
      value: string
      displayName: string
      description: string
      supportsEffort?: boolean
      supportedEffortLevels?: Array<string>
      supportsFastMode?: boolean
    }>
  > {
    return [
      {
        description: "",
        displayName: "Fable 5",
        supportedEffortLevels: ["low", "medium", "high", "xhigh"],
        supportsEffort: true,
        supportsFastMode: true,
        value: "claude-fable-5"
      },
      { description: "", displayName: "Opus 4.8", value: "claude-opus-4-8" }
    ]
  }

  [Symbol.asyncIterator](): AsyncIterator<SDKMessage> {
    return {
      next: (): Promise<IteratorResult<SDKMessage>> => {
        const buffered = this.buffer.shift()
        if (buffered !== undefined) {
          return Promise.resolve({ done: false, value: buffered })
        }
        if (this.ended) {
          return Promise.resolve({ done: true, value: undefined })
        }
        return new Promise((resolvePromise) => {
          this.waiting = resolvePromise
        })
      }
    }
  }
}

const initMessage = (sessionId = "sdk-session-1", model = "claude-fable-5"): SDKMessage =>
  ({
    apiKeySource: "none",
    cwd: "/tmp",
    model,
    session_id: sessionId,
    subtype: "init",
    type: "system"
  }) as never

const resultMessage = (subtype: "success" | "error_during_execution" = "success"): SDKMessage =>
  ({
    duration_ms: 10,
    errors: subtype === "success" ? [] : ["boom"],
    is_error: subtype !== "success",
    num_turns: 1,
    result: "done",
    session_id: "sdk-session-1",
    subtype,
    type: "result"
  }) as never

/// A result message with an explicit `stop_reason` — for the truncation
/// (`max_tokens`) auto-continue path, which keys off it.
const resultWith = (fields: {
  subtype?: "success" | "error_during_execution"
  stop_reason?: string | null
}): SDKMessage => {
  const subtype = fields.subtype ?? "success"
  return {
    duration_ms: 10,
    errors: subtype === "success" ? [] : ["boom"],
    is_error: subtype !== "success",
    num_turns: 1,
    result: "done",
    session_id: "sdk-session-1",
    stop_reason: fields.stop_reason ?? "end_turn",
    subtype,
    type: "result"
  } as never
}

/// An assistant message carrying the SDK's per-message `error` (overloaded,
/// authentication_failed, …) — the signal the provider uses to tell a transient
/// failure (retry) from a permanent one (surface).
const assistantErrorMessage = (error: string): SDKMessage =>
  ({
    error,
    message: { content: [], id: "msg-err", role: "assistant" },
    parent_tool_use_id: null,
    session_id: "sdk-session-1",
    type: "assistant",
    uuid: "00000000-0000-0000-0000-000000000002"
  }) as never

/// A 529-style transient failure that arrives with NO structured error — the CLI
/// renders it as an assistant text message ending on a stop sequence.
const assistantApiErrorMessage = (text: string): SDKMessage =>
  ({
    message: {
      content: [{ text, type: "text" }],
      id: "msg-apierr",
      role: "assistant",
      stop_reason: "stop_sequence"
    },
    parent_tool_use_id: null,
    session_id: "sdk-session-1",
    type: "assistant",
    uuid: "00000000-0000-0000-0000-000000000003"
  }) as never

const streamEvent = (event: unknown, parentToolUseId: string | null = null): SDKMessage =>
  ({
    event,
    parent_tool_use_id: parentToolUseId,
    session_id: "sdk-session-1",
    type: "stream_event",
    uuid: "00000000-0000-0000-0000-000000000000"
  }) as never

const systemMessage = (subtype: string, fields: Record<string, unknown>): SDKMessage =>
  ({
    session_id: "sdk-session-1",
    subtype,
    type: "system",
    uuid: "00000000-0000-0000-0000-000000000001",
    ...fields
  }) as never

const settle = async (): Promise<void> => {
  for (let index = 0; index < 20; index += 1) {
    await Promise.resolve()
  }
}

const makeProvider = (
  fake: FakeQuery,
  checkVersion = async () => "2.1.0",
  getSessionInfo?: NonNullable<ClaudeProviderConfig["getSessionInfo"]>
) =>
  makeClaudeProvider(environment, {
    checkVersion,
    ...(getSessionInfo === undefined ? {} : { getSessionInfo }),
    queryFn: (input) => {
      fake.promptInput = input.prompt
      fake.options = input.options
      void (async () => {
        for await (const message of input.prompt) {
          fake.userMessages.push(message)
        }
      })()
      return fake as never
    },
    readFile: (path) => (path === "/tmp/existing.txt" ? "line1\nline2\nline3\n" : undefined)
  })

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

  it("emits the SDK-generated title after a completed turn", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(
      fake,
      async () => "2.1.0",
      async () =>
        ({
          customTitle: "Harness title",
          sessionId: "sdk-session-1",
          summary: "Generated"
        }) as never
    )
    const events: RuntimeEvent[] = []
    const createPromise = run(
      provider.createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    await settle()
    fake.push(initMessage())
    const created = await createPromise
    const prompt = run(created.handle.prompt("hello"))
    await settle()
    fake.push(resultMessage())
    await prompt
    await settle()

    expect(events.map((event) => event.payload)).toContainEqual({
      sessionUpdate: "session_info_update",
      title: "Harness title"
    })
  })

  it("creates a session against the located binary and reports models/modes", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }

    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
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

  it("reports context occupancy from the latest top-level Claude request", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: RuntimeEvent[] = []
    const createPromise = run(
      provider.createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    await settle()
    fake.push(initMessage("sdk-session-1", "claude-sonnet-4-6"))
    const created = await createPromise
    const prompt = run(created.handle.prompt("hello"))
    await settle()

    fake.push({
      message: {
        content: [],
        id: "msg-usage",
        model: "claude-sonnet-4-6",
        role: "assistant",
        usage: {
          cache_creation_input_tokens: 1_500,
          cache_read_input_tokens: 30_000,
          input_tokens: 1_300,
          output_tokens: 100
        }
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "assistant",
      uuid: "00000000-0000-0000-0000-000000000004"
    } as never)
    fake.push({
      ...resultMessage(),
      modelUsage: {
        "claude-sonnet-4-6": { contextWindow: 200_000 }
      },
      total_cost_usd: 0.25,
      usage: { input_tokens: 1_300, output_tokens: 100 }
    } as never)

    await prompt
    await settle()

    const update = events.find(
      (event) =>
        event.kind === "session.updated" &&
        (event.payload as Record<string, unknown>).sessionUpdate === "usage_update"
    )
    expect(update?.payload as Record<string, unknown>).toMatchObject({
      sessionUpdate: "usage_update",
      size: 200_000,
      used: 32_800
    })
  })

  it("normalizes malformed init model ids before updating config options", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }

    const created = await run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage("sdk-session-1", "claude-fable-5\u001b[1m"))
    await settle()
    await run(created.handle.setConfigOption("speed", "fast"))

    const updated = events.at(-1)?.payload as {
      configOptions?: Array<{ currentValue: string; id: string }>
    }
    const model = updated.configOptions?.find((option) => option.id === "model")
    expect(model?.currentValue).toBe("claude-fable-5")
    const effort = updated.configOptions?.find((option) => option.id === "effort")
    expect(effort?.currentValue).toBe("high")
  })

  it("keeps the last known picker model when a later init reports an unknown model", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }

    const created = await run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage("sdk-session-1", "claude-not-in-picker"))
    await settle()
    await run(created.handle.setConfigOption("speed", "fast"))

    const updated = events.at(-1)?.payload as {
      configOptions?: Array<{ currentValue: string; id: string }>
    }
    const model = updated.configOptions?.find((option) => option.id === "model")
    expect(model?.currentValue).toBe("claude-fable-5")
    const effort = updated.configOptions?.find((option) => option.id === "effort")
    expect(effort?.currentValue).toBe("high")
  })

  it("exposes speed for fast-mode models and applies it via flag settings", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }

    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const speed = created.metadata.configOptions.find((option) => option.id === "speed")
    expect(speed).toMatchObject({ category: "speed", currentValue: "standard", name: "Speed" })
    expect(speed?.options.map((option) => ("value" in option ? option.value : undefined))).toEqual([
      "standard",
      "fast"
    ])

    await run(created.handle.setConfigOption("speed", "fast"))
    expect(fake.flagSettings).toEqual([{ fastMode: true }])
    const updated = events.at(-1)?.payload as Record<string, unknown>
    expect(updated.configId).toBe("speed")
    expect(updated.configOptions).toContainEqual(
      expect.objectContaining({ currentValue: "fast", id: "speed" })
    )

    // Switching to a model without fast mode drops the option and turns
    // fast mode off.
    await run(created.handle.setConfigOption("model", "claude-opus-4-8"))
    expect(fake.flagSettings).toEqual([{ fastMode: true }, { fastMode: false }])
    const afterModel = events.at(-1)?.payload as Record<string, unknown>
    expect(afterModel.configOptions).not.toContainEqual(expect.objectContaining({ id: "speed" }))
  })

  it("seeds the speed from the init message's fast mode state", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push({ ...(initMessage() as object), fast_mode_state: "on" } as never)
    const created = await createPromise

    // The init lands after createSession's metadata snapshot in some orders;
    // read the live options through a config change instead.
    await run(created.handle.setConfigOption("effort", "medium"))
    const updated = events.at(-1)?.payload as Record<string, unknown>
    const speed = (
      updated.configOptions as Array<{ id: string; currentValue: string }> | undefined
    )?.find((option) => option.id === "speed")
    expect(speed?.currentValue).toBe("fast")
  })

  it("rejects claude binaries older than the version floor", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake, async () => "1.0.44")
    await expect(
      run(provider.createSession(definition, "/tmp", async () => undefined))
    ).rejects.toThrow("older than the required")
  })

  it("streams a full edit turn: lifecycle, throttled diff stats, terminal status", async () => {
    vi.useFakeTimers({ now: 1_000_000 })
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }

    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("edit the file"))
    await settle()
    expect(fake.userMessages).toHaveLength(1)

    fake.push(streamEvent({ message: { id: "msg-1" }, type: "message_start" }))
    fake.push(
      streamEvent({
        content_block: { id: "tool-1", name: "Edit", type: "tool_use" },
        index: 1,
        type: "content_block_start"
      })
    )
    // First delta carries the path and the old_string; later deltas stream new_string.
    fake.push(
      streamEvent({
        delta: {
          partial_json:
            '{"file_path":"/tmp/a.txt","old_string":"one\\ntwo\\n","new_string":"one\\n',
          type: "input_json_delta"
        },
        index: 1,
        type: "content_block_delta"
      })
    )
    await settle()
    vi.setSystemTime(1_000_300)
    fake.push(
      streamEvent({
        delta: { partial_json: "three\\nfour\\n", type: "input_json_delta" },
        index: 1,
        type: "content_block_delta"
      })
    )
    await settle()
    fake.push(streamEvent({ index: 1, type: "content_block_stop" }))
    await settle()
    fake.push({
      message: {
        content: [
          {
            id: "tool-1",
            input: {
              file_path: "/tmp/a.txt",
              new_string: "one\nthree\nfour\n",
              old_string: "one\ntwo\n"
            },
            name: "Edit",
            type: "tool_use"
          }
        ],
        role: "assistant"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "assistant"
    } as never)
    fake.push({
      message: {
        content: [{ content: "ok", is_error: false, tool_use_id: "tool-1", type: "tool_result" }],
        role: "user"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "user"
    } as never)
    fake.push(resultMessage())
    const result = await promptPromise
    expect(result.stopReason).toBe("end_turn")

    // The session-start background-task snapshot precedes turn output.
    const payloads = events
      .map((event) => event.payload as Record<string, unknown>)
      .filter((payload) => payload.backgroundTasks === undefined)
    expect(payloads[0]).toMatchObject({ initiatedBy: "user", turnState: "started" })
    expect(payloads[1]).toMatchObject({
      sessionUpdate: "tool_call",
      toolCallId: "tool-1",
      status: "in_progress",
      kind: "edit"
    })
    const statUpdates = payloads.filter(
      (payload) => payload.sessionUpdate === "tool_call_update" && payload.diffStats !== undefined
    )
    expect(statUpdates.length).toBeGreaterThanOrEqual(2)
    const firstStats = statUpdates[0]?.diffStats as Array<{ added: number; removed: number }>
    const lastStreamed = statUpdates.at(-2)?.diffStats as Array<{ added: number; removed: number }>
    expect(firstStats[0]?.removed).toBe(2)
    expect(firstStats[0]?.added).toBe(1)
    // Counts grew monotonically as new_string streamed in.
    expect(lastStreamed[0]?.added).toBeGreaterThanOrEqual(firstStats[0]?.added ?? 0)
    // The consolidated input recomputes authoritative stats via a real diff
    // (common "one" line drops out: +2/−1).
    const authoritative = statUpdates.at(-1)?.diffStats as Array<{ added: number; removed: number }>
    expect(authoritative[0]).toMatchObject({ added: 2, removed: 1 })

    expect(payloads).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "tool_call_update",
        status: "completed",
        toolCallId: "tool-1"
      })
    )
    expect(payloads.at(-1)).toMatchObject({
      stopReason: "end_turn",
      turnState: "ended",
      initiatedBy: "user"
    })
  })

  it("opens an agent-initiated turn for output with no prompt in flight", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    await createPromise

    fake.push(streamEvent({ message: { id: "msg-bg" }, type: "message_start" }))
    fake.push(
      streamEvent({
        delta: { text: "Background task finished.", type: "text_delta" },
        index: 0,
        type: "content_block_delta"
      })
    )
    fake.push(resultMessage())
    await settle()

    // The session-start background-task snapshot precedes turn output.
    const payloads = events
      .map((event) => event.payload as Record<string, unknown>)
      .filter((payload) => payload.backgroundTasks === undefined)
    expect(payloads[0]).toMatchObject({ initiatedBy: "agent", turnState: "started" })
    expect(payloads[1]).toMatchObject({
      sessionUpdate: "agent_message_chunk",
      messageId: "msg-bg"
    })
    expect(payloads.at(-1)).toMatchObject({
      initiatedBy: "agent",
      stopReason: "end_turn",
      turnState: "ended"
    })
  })

  it("renders plan tools as plan updates, never as tool calls", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise
    const promptPromise = run(created.handle.prompt("plan the feature"))
    await settle()

    // TodoWrite streams like any tool, but must not open a tool call.
    fake.push(streamEvent({ message: { id: "msg-plan" }, type: "message_start" }))
    fake.push(
      streamEvent({
        content_block: { id: "todo-1", name: "TodoWrite", type: "tool_use" },
        index: 1,
        type: "content_block_start"
      })
    )
    await settle()
    fake.push({
      message: {
        content: [
          {
            id: "todo-1",
            input: {
              todos: [
                { activeForm: "Exploring", content: "Explore the code", status: "completed" },
                { activeForm: "Designing", content: "Design the fix", status: "in_progress" },
                { activeForm: "Testing", content: "Add tests", status: "someday" },
                { content: 42, status: "pending" },
                "not-a-todo"
              ]
            },
            name: "TodoWrite",
            type: "tool_use"
          }
        ],
        role: "assistant"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "assistant"
    } as never)
    fake.push({
      message: {
        content: [{ content: "ok", is_error: false, tool_use_id: "todo-1", type: "tool_result" }],
        role: "user"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "user"
    } as never)

    // ExitPlanMode carries the plan-mode plan document in input.plan.
    fake.push(
      streamEvent({
        content_block: { id: "exit-1", name: "ExitPlanMode", type: "tool_use" },
        index: 2,
        type: "content_block_start"
      })
    )
    await settle()
    fake.push({
      message: {
        content: [
          {
            id: "exit-1",
            input: { plan: "# The Plan\n\n1. Do the thing\n2. Verify it" },
            name: "ExitPlanMode",
            type: "tool_use"
          },
          // Malformed plan input emits nothing (and still no tool call).
          { id: "exit-2", input: {}, name: "ExitPlanMode", type: "tool_use" }
        ],
        role: "assistant"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "assistant"
    } as never)
    fake.push(resultMessage())
    await promptPromise

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    // No tool-call lifecycle at all for plan tools — including the turn-end
    // settle sweep (they were never registered as open).
    expect(
      payloads.filter(
        (payload) =>
          payload.sessionUpdate === "tool_call" || payload.sessionUpdate === "tool_call_update"
      )
    ).toEqual([])
    const plan = payloads.find((payload) => payload.sessionUpdate === "plan")
    expect(plan?.entries).toEqual([
      { content: "Explore the code", priority: "medium", status: "completed" },
      { content: "Design the fix", priority: "medium", status: "in_progress" },
      { content: "Add tests", priority: "medium", status: "pending" }
    ])
    const documents = payloads.filter((payload) => payload.sessionUpdate === "plan_document")
    expect(documents).toEqual([
      { markdown: "# The Plan\n\n1. Do the thing\n2. Verify it", sessionUpdate: "plan_document" }
    ])
  })

  it("renders incremental Task tools as checklist snapshots outside plan mode", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const createPromise = run(
      provider.createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    await settle()
    fake.push(initMessage())
    const created = await createPromise
    expect(created.metadata.modes?.currentModeId).toBe("bypassPermissions")

    const promptPromise = run(created.handle.prompt("make a checklist"))
    await settle()
    fake.push(streamEvent({ message: { id: "msg-tasks" }, type: "message_start" }))
    fake.push(
      streamEvent({
        content_block: { id: "create-1", name: "TaskCreate", type: "tool_use" },
        index: 1,
        type: "content_block_start"
      })
    )
    fake.push({
      message: {
        content: [
          {
            id: "create-1",
            input: {
              activeForm: "Writing tests",
              description: "Cover the task flow",
              subject: "Write tests"
            },
            name: "TaskCreate",
            type: "tool_use"
          }
        ],
        role: "assistant"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "assistant"
    } as never)

    const taskCreatedHook = fake.options?.hooks?.TaskCreated?.[0]?.hooks[0]
    expect(taskCreatedHook).toBeDefined()
    await taskCreatedHook?.(
      {
        hook_event_name: "TaskCreated",
        session_id: "sdk-session-1",
        task_description: "Cover the task flow",
        task_id: "1",
        task_subject: "Write tests"
      } as never,
      "create-1",
      { signal: new AbortController().signal }
    )
    fake.push({
      message: {
        content: [
          {
            content: "Task #1 created successfully: Write tests",
            is_error: false,
            tool_use_id: "create-1",
            type: "tool_result"
          }
        ],
        role: "user"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "user"
    } as never)

    fake.push(
      streamEvent({
        content_block: { id: "update-1", name: "TaskUpdate", type: "tool_use" },
        index: 2,
        type: "content_block_start"
      })
    )
    fake.push({
      message: {
        content: [
          {
            id: "update-1",
            input: { status: "in_progress", taskId: "1" },
            name: "TaskUpdate",
            type: "tool_use"
          }
        ],
        role: "assistant"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "assistant"
    } as never)
    fake.push({
      message: {
        content: [
          {
            content: "Updated task #1 status",
            is_error: false,
            tool_use_id: "update-1",
            type: "tool_result"
          }
        ],
        role: "user"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "user"
    } as never)
    await settle()

    const taskCompletedHook = fake.options?.hooks?.TaskCompleted?.[0]?.hooks[0]
    expect(taskCompletedHook).toBeDefined()
    await taskCompletedHook?.(
      {
        hook_event_name: "TaskCompleted",
        session_id: "sdk-session-1",
        task_id: "1",
        task_subject: "Write tests"
      } as never,
      "update-2",
      { signal: new AbortController().signal }
    )
    fake.push(resultMessage())
    await promptPromise

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(
      payloads.filter(
        (payload) =>
          payload.sessionUpdate === "tool_call" || payload.sessionUpdate === "tool_call_update"
      )
    ).toEqual([])
    expect(payloads.filter((payload) => payload.sessionUpdate === "plan")).toEqual([
      {
        entries: [{ content: "Write tests", priority: "medium", status: "pending" }],
        sessionUpdate: "plan"
      },
      {
        entries: [{ content: "Write tests", priority: "medium", status: "in_progress" }],
        sessionUpdate: "plan"
      },
      {
        entries: [{ content: "Write tests", priority: "medium", status: "completed" }],
        sessionUpdate: "plan"
      }
    ])
  })

  it("recovers a TaskCreate id from Claude's rendered tool result", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const created = await run(
      provider.createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    const promptPromise = run(created.handle.prompt("make a task"))
    await settle()

    fake.push(
      streamEvent({
        content_block: { id: "create-fallback", name: "TaskCreate", type: "tool_use" },
        index: 1,
        type: "content_block_start"
      })
    )
    fake.push({
      message: {
        content: [
          {
            id: "create-fallback",
            input: { description: "Fallback coverage", subject: "Recovered task" },
            name: "TaskCreate",
            type: "tool_use"
          }
        ],
        role: "assistant"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "assistant"
    } as never)
    fake.push({
      message: {
        content: [
          {
            content: "Task #42 created successfully: Recovered task",
            is_error: false,
            tool_use_id: "create-fallback",
            type: "tool_result"
          }
        ],
        role: "user"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "user"
    } as never)
    fake.push(resultMessage())
    await promptPromise

    expect(
      events
        .map((event) => event.payload as Record<string, unknown>)
        .find((payload) => payload.sessionUpdate === "plan")
    ).toEqual({
      entries: [{ content: "Recovered task", priority: "medium", status: "pending" }],
      sessionUpdate: "plan"
    })
  })

  it("surfaces tool approvals as Allow/Deny questions in ask modes", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const toolInput = { command: "rm -rf build" }
    const decision = fake.options!.canUseTool!("Bash", toolInput as never, {} as never)
    await settle()
    const asked = events.at(-1)?.payload as Record<string, unknown>
    expect(asked).toMatchObject({ sessionUpdate: "question" })
    expect(asked.questions).toEqual([
      {
        allowsOther: false,
        header: "Permission",
        id: "approval",
        options: [{ label: "Allow" }, { label: "Deny" }],
        question: "Allow Bash?"
      }
    ])
    await run(
      created.handle.answerQuestion!(asked.questionId as string, {
        answers: { approval: { answers: ["Allow"] } },
        outcome: "answered"
      })
    )
    await expect(decision).resolves.toEqual({ behavior: "allow", updatedInput: toolInput })

    // Deny (and dismissal) reject the tool.
    const denied = fake.options!.canUseTool!("Edit", { file_path: "/tmp/a" } as never, {} as never)
    await settle()
    const deniedAsk = events.at(-1)?.payload as Record<string, unknown>
    await run(
      created.handle.answerQuestion!(deniedAsk.questionId as string, {
        answers: { approval: { answers: ["Deny"] } },
        outcome: "answered"
      })
    )
    await expect(denied).resolves.toEqual({
      behavior: "deny",
      message: "User denied permission."
    })
  })

  it("surfaces ExitPlanMode as a plan-approval question: implement allows, keep planning denies", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const toolInput = { plan: "# The Plan\n\n1. Do it" }
    const decision = fake.options!.canUseTool!("ExitPlanMode", toolInput as never, {} as never)
    await settle()
    const asked = events.at(-1)?.payload as Record<string, unknown>
    expect(asked).toMatchObject({ sessionUpdate: "question" })
    // No "message" line — the plan itself rides a separate plan_document.
    expect(asked.message).toBeUndefined()
    expect(asked.questions).toEqual([
      {
        allowsOther: false,
        header: "Plan",
        id: "exit_plan_mode",
        options: [
          { description: "Start building", label: "Implement plan" },
          { description: "Keep refining in plan mode", label: "Keep planning" }
        ],
        question: "Ready to implement this plan?"
      }
    ])
    await run(
      created.handle.answerQuestion!(asked.questionId as string, {
        answers: { exit_plan_mode: { answers: ["Implement plan"] } },
        outcome: "answered"
      })
    )
    await expect(decision).resolves.toEqual({ behavior: "allow", updatedInput: toolInput })

    // Keeping planning denies the tool with a message that nudges more planning.
    const kept = fake.options!.canUseTool!("ExitPlanMode", toolInput as never, {} as never)
    await settle()
    const keptAsk = events.at(-1)?.payload as Record<string, unknown>
    await run(
      created.handle.answerQuestion!(keptAsk.questionId as string, {
        answers: { exit_plan_mode: { answers: ["Keep planning"] } },
        outcome: "answered"
      })
    )
    await expect(kept).resolves.toEqual({
      behavior: "deny",
      message: "The user wants to keep refining the plan. Stay in plan mode and continue planning."
    })
  })

  it("drives goal mode through /goal slash commands with synthetic snapshots", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise
    expect(created.metadata.supportsGoals).toBe(true)

    const goal = await run(created.handle.setGoal!({ objective: "ship the feature" }))
    await settle()
    expect(goal.objective).toBe("ship the feature")
    expect(goal.status).toBe("active")
    const commandTexts = fake.userMessages.map((message) => {
      const content = (message as { message: { content: unknown } }).message.content
      return Array.isArray(content) ? (content[0] as { text?: string }).text : content
    })
    expect(commandTexts).toEqual(["/goal ship the feature"])
    expect(events.at(-1)?.payload).toMatchObject({ goal: { objective: "ship the feature" } })

    // Pause/resume map to subcommands and update the synthetic snapshot.
    const paused = await run(created.handle.setGoal!({ status: "paused" }))
    await settle()
    expect(paused.status).toBe("paused")
    await run(created.handle.setGoal!({ status: "active" }))
    await settle()

    await run(created.handle.clearGoal!)
    await settle()
    const finalTexts = fake.userMessages.map((message) => {
      const content = (message as { message: { content: unknown } }).message.content
      return Array.isArray(content) ? (content[0] as { text?: string }).text : content
    })
    expect(finalTexts).toEqual([
      "/goal ship the feature",
      "/goal pause",
      "/goal resume",
      "/goal clear"
    ])
    expect(events.at(-1)?.payload).toEqual({ goalCleared: true })

    // Status updates without an active goal are rejected.
    await expect(run(created.handle.setGoal!({ status: "paused" }))).rejects.toThrow(
      "No active goal"
    )
  })

  it("settles the goal when its turn ends: success completes, interrupt pauses", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    // The /goal turn's successful result marks the goal complete — the SDK
    // stream has no goal-state messages to relay.
    await run(created.handle.setGoal!({ objective: "count to ten" }))
    fake.push(resultMessage())
    await settle()
    const completed = events.findLast((event) => {
      const payload = event.payload as Record<string, unknown>
      return payload.goal !== undefined
    })?.payload as Record<string, unknown>
    expect(completed.goal).toMatchObject({ objective: "count to ten", status: "complete" })

    // A new goal interrupted mid-run pauses instead (resumable).
    await run(created.handle.setGoal!({ objective: "count to twenty" }))
    await run(created.handle.cancel)
    fake.push(resultMessage())
    await settle()
    const paused = events.findLast((event) => {
      const payload = event.payload as Record<string, unknown>
      return payload.goal !== undefined
    })?.payload as Record<string, unknown>
    expect(paused.goal).toMatchObject({ objective: "count to twenty", status: "paused" })
  })

  it("blocks AskUserQuestion on the human's answer and folds it into updatedInput", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const toolInput = {
      questions: [
        {
          header: "Auth",
          multiSelect: false,
          options: [
            { description: "Fast to ship.", label: "JWT (Recommended)" },
            { description: "Simpler infra.", label: "Sessions" }
          ],
          question: "Which auth method?"
        },
        {
          multiSelect: true,
          options: [{ label: "Web" }, { label: "iOS" }],
          question: "Which platforms?"
        }
      ]
    }
    const decision = fake.options!.canUseTool!("AskUserQuestion", toolInput as never, {} as never)
    await settle()
    const asked = events.at(-1)?.payload as Record<string, unknown>
    expect(asked.sessionUpdate).toBe("question")
    const questionId = asked.questionId as string
    expect(asked.questions).toMatchObject([
      { allowsOther: true, header: "Auth", id: "question_0" },
      { allowsOther: true, id: "question_1", multiSelect: true }
    ])

    await run(
      created.handle.answerQuestion!(questionId, {
        answers: {
          question_0: { answers: [], note: "Use magic links" },
          question_1: { answers: ["Web", "iOS"], note: "mobile can come later" }
        },
        outcome: "answered"
      })
    )
    // A bare note is the answer (the "Other" path); a note alongside labels
    // supplements them; keys are the question text (the SDK tool reads them
    // back that way).
    await expect(decision).resolves.toEqual({
      behavior: "allow",
      updatedInput: {
        ...toolInput,
        answers: {
          "Which auth method?": "Use magic links",
          "Which platforms?": "Web, iOS — mobile can come later"
        }
      }
    })
    expect(events.at(-1)?.payload).toMatchObject({
      outcome: "answered",
      questionId,
      sessionUpdate: "question_resolved"
    })
    // No tool_call lifecycle leaked for the question tool.
    expect(
      events.filter((event) => {
        const payload = event.payload as Record<string, unknown>
        return payload.sessionUpdate === "tool_call" || payload.sessionUpdate === "tool_call_update"
      })
    ).toEqual([])
  })

  it("cancelling a question denies the tool; interrupts deny all held questions", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const ask = (question: string) =>
      fake.options!.canUseTool!(
        "AskUserQuestion",
        { questions: [{ options: [{ label: "A" }], question }] } as never,
        {} as never
      )

    const first = ask("First?")
    await settle()
    const firstId = (events.at(-1)?.payload as Record<string, unknown>).questionId as string
    await run(created.handle.answerQuestion!(firstId, { outcome: "cancelled" }))
    await expect(first).resolves.toEqual({
      behavior: "deny",
      message: "User dismissed the question without answering."
    })

    // Unknown ids fail; malformed inputs pass straight through as allow.
    await expect(
      run(created.handle.answerQuestion!("nope", { outcome: "answered" }))
    ).rejects.toThrow("No pending question")
    await expect(
      fake.options!.canUseTool!("AskUserQuestion", { questions: "?" } as never, {} as never)
    ).resolves.toMatchObject({ behavior: "allow" })

    const second = ask("Second?")
    await settle()
    await run(created.handle.cancel)
    await expect(second).resolves.toMatchObject({ behavior: "deny" })
    expect(events.at(-1)?.payload).toMatchObject({
      outcome: "cancelled",
      sessionUpdate: "question_resolved"
    })
  })

  it("cancels: interrupt settles open tool calls and ends the turn cancelled", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("do work"))
    await settle()
    fake.push(
      streamEvent({
        content_block: { id: "tool-9", name: "Bash", type: "tool_use" },
        index: 0,
        type: "content_block_start"
      })
    )
    await settle()
    await run(created.handle.cancel)
    expect(fake.interrupts).toHaveLength(1)
    fake.push(resultMessage("error_during_execution"))
    const result = await promptPromise
    expect(result.stopReason).toBe("cancelled")

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "tool_call_update",
        status: "cancelled",
        toolCallId: "tool-9"
      })
    )
    // A cancelled turn is not an error.
    expect(events.every((event) => event.kind !== "session.error")).toBe(true)
  })

  it("auto-continues a turn truncated by the output-token cap, then ends on the next result", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("write a very long file"))
    await settle()
    expect(fake.userMessages).toHaveLength(1) // just the user's prompt so far

    // The model streams some text, then the response is cut off by the
    // per-response output-token cap (stop_reason "max_tokens").
    fake.push(streamEvent({ message: { id: "msg-1" }, type: "message_start" }))
    fake.push(
      streamEvent({
        delta: { text: "Working…", type: "text_delta" },
        index: 0,
        type: "content_block_delta"
      })
    )
    await settle()
    fake.push(resultWith({ stop_reason: "max_tokens" }))
    await settle()

    const endedEvents = () =>
      events.filter(
        (event) =>
          event.kind === "session.updated" &&
          (event.payload as Record<string, unknown>).turnState === "ended"
      )
    const continuations = () =>
      fake.userMessages.filter((message) => message.message.content === "Please continue.")

    // A continuation was pushed to the live SDK query, the turn did NOT end,
    // and the awaiting prompt is still unresolved.
    expect(continuations()).toHaveLength(1)
    expect(endedEvents()).toHaveLength(0)

    // The model finishes the continuation normally; now the turn ends and the
    // prompt resolves with a clean stop reason.
    fake.push(resultWith({ stop_reason: "end_turn" }))
    const result = await promptPromise
    expect(result.stopReason).toBe("end_turn")
    expect(endedEvents()).toHaveLength(1)
  })

  it("stops auto-continuing once the per-turn continuation budget is exhausted", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("keep truncating"))
    await settle()

    // MAX_AUTO_CONTINUATIONS (12) continuations are issued, then the 13th
    // truncation ends the turn instead of looping forever.
    for (let index = 0; index < 13; index += 1) {
      fake.push(resultWith({ stop_reason: "max_tokens" }))
      await settle()
    }
    const result = await promptPromise
    expect(result.stopReason).toBe("end_turn")

    const continuations = fake.userMessages.filter(
      (message) => message.message.content === "Please continue."
    )
    expect(continuations).toHaveLength(12)
  })

  it("ends an in-flight turn if the SDK stream dies without a final result", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("do work"))
    await settle()
    // Open a tool call so we can prove it gets settled on the safety-net path.
    fake.push(
      streamEvent({
        content_block: { id: "tool-x", name: "Bash", type: "tool_use" },
        index: 0,
        type: "content_block_start"
      })
    )
    await settle()

    // The SDK stream ends mid-turn with no `result` (query closed/crashed).
    fake.finish()
    const result = await promptPromise
    expect(result.stopReason).toBe("end_turn")

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads).toContainEqual(expect.objectContaining({ turnState: "ended" }))
    expect(payloads).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "tool_call_update",
        status: "failed",
        toolCallId: "tool-x"
      })
    )
  })

  it("auto-retries a transient API error after backoff, then ends on success", async () => {
    vi.useFakeTimers()
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("do work"))
    await settle()
    expect(fake.userMessages).toHaveLength(1) // just the user's prompt

    // The API is overloaded: the SDK reports it on the assistant message, then
    // gives up and ends the turn with error_during_execution.
    fake.push(assistantErrorMessage("overloaded"))
    fake.push(resultMessage("error_during_execution"))
    await settle()

    const continuations = () =>
      fake.userMessages.filter((message) => message.message.content === "Please continue.")
    const endedEvents = () =>
      events.filter(
        (event) =>
          event.kind === "session.updated" &&
          (event.payload as Record<string, unknown>).turnState === "ended"
      )

    // Backoff: not resumed yet, turn still alive, nothing surfaced.
    expect(continuations()).toHaveLength(0)
    expect(endedEvents()).toHaveLength(0)
    expect(events.some((event) => event.kind === "session.error")).toBe(false)

    // Once the backoff elapses the turn resumes automatically.
    await vi.advanceTimersByTimeAsync(1000)
    await settle()
    expect(continuations()).toHaveLength(1)
    expect(endedEvents()).toHaveLength(0)

    // The retry succeeds; the turn ends cleanly with no error surfaced.
    fake.push(resultMessage("success"))
    await settle()
    const result = await promptPromise
    expect(result.stopReason).toBe("end_turn")
    expect(endedEvents()).toHaveLength(1)
    expect(events.some((event) => event.kind === "session.error")).toBe(false)
  })

  it("retries a 529 that arrives as text (no structured error), then surfaces it", async () => {
    vi.useFakeTimers()
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("do work"))
    await settle()

    const errorText = "API Error: 529 Overloaded. This is a server-side issue; please retry."
    const continuations = () =>
      fake.userMessages.filter((message) => message.message.content === "Please continue.")
    const retryingEvents = () =>
      events.filter(
        (event) =>
          event.kind === "session.updated" &&
          (event.payload as Record<string, unknown>).retrying !== undefined
      )
    const endedEvents = () =>
      events.filter(
        (event) =>
          event.kind === "session.updated" &&
          (event.payload as Record<string, unknown>).turnState === "ended"
      )

    // Three visible retries (MAX_TRANSIENT_RETRIES): the 529 arrives as text with
    // no structured error, but is still detected, retried, and shown.
    for (let attempt = 1; attempt <= 3; attempt += 1) {
      fake.push(assistantApiErrorMessage(errorText))
      fake.push(resultMessage("success"))
      await settle()
      expect(retryingEvents()).toHaveLength(attempt)
      expect(endedEvents()).toHaveLength(0)
      expect(events.some((event) => event.kind === "session.error")).toBe(false)
      await vi.advanceTimersByTimeAsync(8000)
      await settle()
      expect(continuations()).toHaveLength(attempt)
    }

    // Retries exhausted → end, surfacing the real error text in stopDetail.
    fake.push(assistantApiErrorMessage(errorText))
    fake.push(resultMessage("success"))
    await settle()
    const result = await promptPromise
    expect(result.stopReason).toBe("end_turn")
    const endedPayload = events
      .map((event) => event.payload as Record<string, unknown>)
      .find((payload) => payload.turnState === "ended")
    expect(endedPayload?.stopDetail).toBe(errorText)
    expect(endedPayload?.retryable).toBe(true)
    expect(retryingEvents()).toHaveLength(3)
  })

  it("surfaces a permanent API error immediately, with no retry", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("do work"))
    await settle()

    fake.push(assistantErrorMessage("authentication_failed"))
    fake.push(resultMessage("error_during_execution"))
    const result = await promptPromise
    expect(result.stopReason).toBe("end_turn")

    // No auto-retry, and the turn ends carrying a human-readable stopDetail
    // instead of a session-global error banner.
    expect(
      fake.userMessages.filter((message) => message.message.content === "Please continue.")
    ).toHaveLength(0)
    const endedPayload = events
      .map((event) => event.payload as Record<string, unknown>)
      .find((payload) => payload.turnState === "ended")
    expect(endedPayload?.stopDetail).toBe("Claude authentication failed.")
    expect(events.some((event) => event.kind === "session.error")).toBe(false)
  })

  it("doesn't resume a transient-error turn after the session closes", async () => {
    vi.useFakeTimers()
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    void run(created.handle.prompt("do work"))
    await settle()

    fake.push(assistantErrorMessage("overloaded"))
    fake.push(resultMessage("error_during_execution"))
    await settle()
    const continuations = () =>
      fake.userMessages.filter((message) => message.message.content === "Please continue.")
    expect(continuations()).toHaveLength(0) // scheduled, not yet fired

    // Close the session, then let the backoff elapse — a dead session must not
    // be resumed by a lingering timer.
    await run(created.handle.close)
    await vi.advanceTimersByTimeAsync(8000)
    await settle()
    expect(continuations()).toHaveLength(0)
  })

  it("tags subagent tool calls, prose and thinking with parentToolCallId", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("spawn an agent"))
    await settle()
    fake.push(streamEvent({ message: { id: "msg-sub-1" }, type: "message_start" }, "parent-task-1"))
    fake.push(
      streamEvent(
        {
          content_block: { id: "sub-tool-1", name: "Read", type: "tool_use" },
          index: 0,
          type: "content_block_start"
        },
        "parent-task-1"
      )
    )
    fake.push(
      streamEvent(
        {
          delta: { text: "subagent prose", type: "text_delta" },
          index: 1,
          type: "content_block_delta"
        },
        "parent-task-1"
      )
    )
    fake.push(
      streamEvent(
        {
          delta: { thinking: "subagent thought", type: "thinking_delta" },
          index: 2,
          type: "content_block_delta"
        },
        "parent-task-1"
      )
    )
    fake.push(resultMessage())
    await promptPromise

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "tool_call",
        toolCallId: "sub-tool-1",
        parentToolCallId: "parent-task-1"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        content: { text: "subagent prose", type: "text" },
        messageId: "msg-sub-1",
        parentToolCallId: "parent-task-1",
        sessionUpdate: "agent_message_chunk"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        content: { text: "subagent thought", type: "text" },
        parentToolCallId: "parent-task-1",
        sessionUpdate: "agent_thought_chunk"
      })
    )
    // Subagent chunks never carry the main agent's message id, and main-agent
    // chunks never carry a parent attribution.
    expect(
      payloads.some(
        (payload) =>
          payload.sessionUpdate === "agent_message_chunk" &&
          payload.parentToolCallId === undefined &&
          JSON.stringify(payload.content).includes("subagent")
      )
    ).toBe(false)
  })

  it("maps the Task and Agent tools to kind agent", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("spawn an agent"))
    await settle()
    fake.push(
      streamEvent({
        content_block: { id: "task-1", name: "Task", type: "tool_use" },
        index: 0,
        type: "content_block_start"
      })
    )
    fake.push(
      streamEvent({
        content_block: { id: "task-2", name: "Agent", type: "tool_use" },
        index: 1,
        type: "content_block_start"
      })
    )
    fake.push(resultMessage())
    await promptPromise

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads).toContainEqual(
      expect.objectContaining({ kind: "agent", sessionUpdate: "tool_call", toolCallId: "task-1" })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({ kind: "agent", sessionUpdate: "tool_call", toolCallId: "task-2" })
    )
  })

  it("titles web searches with their query and maps them to kind web_search", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("look it up"))
    await settle()
    fake.push(
      streamEvent({
        content_block: { id: "ws-1", name: "WebSearch", type: "tool_use" },
        index: 0,
        type: "content_block_start"
      })
    )
    fake.push({
      message: {
        content: [
          {
            id: "ws-1",
            input: { query: "swift concurrency actors" },
            name: "WebSearch",
            type: "tool_use"
          },
          {
            id: "wf-1",
            input: { url: "https://example.com/docs" },
            name: "WebFetch",
            type: "tool_use"
          }
        ],
        role: "assistant"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "assistant"
    } as never)
    fake.push(resultMessage())
    await promptPromise

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads).toContainEqual(
      expect.objectContaining({
        kind: "web_search",
        sessionUpdate: "tool_call",
        toolCallId: "ws-1"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        kind: "web_search",
        sessionUpdate: "tool_call_update",
        title: "Searched for swift concurrency actors",
        toolCallId: "ws-1"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        kind: "fetch",
        sessionUpdate: "tool_call_update",
        title: "Fetched https://example.com/docs",
        toolCallId: "wf-1"
      })
    )
  })

  it("surfaces WebSearch result sources as resource_link content", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("look it up"))
    await settle()
    // The WebSearch tool_result is a plain string with an embedded Links array
    // (verbatim shape from the Claude CLI).
    const resultText =
      'Web search results for query: "swift release"\n\n' +
      'Links: [{"title":"Swift 6.2 Released | Swift.org","url":"https://www.swift.org/blog/swift-6.2-released/"},' +
      '{"title":"Releases · swiftlang/swift","url":"https://github.com/swiftlang/swift/releases"}]\n\n' +
      "Swift 6.2 was released on September 15, 2025."
    fake.push({
      message: {
        content: [
          { content: resultText, is_error: false, tool_use_id: "ws-1", type: "tool_result" }
        ],
        role: "user"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "user"
    } as never)
    fake.push(resultMessage())
    await promptPromise

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    const update = payloads.find(
      (payload) =>
        payload.sessionUpdate === "tool_call_update" &&
        payload.toolCallId === "ws-1" &&
        Array.isArray(payload.content)
    )
    expect(update?.content).toEqual([
      {
        content: {
          name: "Swift 6.2 Released | Swift.org",
          title: "Swift 6.2 Released | Swift.org",
          type: "resource_link",
          uri: "https://www.swift.org/blog/swift-6.2-released/"
        },
        type: "content"
      },
      {
        content: {
          name: "Releases · swiftlang/swift",
          title: "Releases · swiftlang/swift",
          type: "resource_link",
          uri: "https://github.com/swiftlang/swift/releases"
        },
        type: "content"
      }
    ])
  })

  it("emits subagent prose and tools from consolidated assistant messages", async () => {
    // Ground truth from current claude CLIs: subagent stream events are NOT
    // forwarded; a subagent's thread exists only in consolidated assistant
    // messages carrying parent_tool_use_id.
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("spawn an agent"))
    await settle()
    fake.push({
      message: {
        content: [
          { text: "Looking at the files now.", type: "text" },
          {
            id: "sub-bash-1",
            input: { command: "ls -la", description: "List files" },
            name: "Bash",
            type: "tool_use"
          }
        ],
        id: "msg-sub-agent-1",
        role: "assistant"
      },
      parent_tool_use_id: "parent-agent-1",
      session_id: "sdk-session-1",
      type: "assistant"
    } as never)
    fake.push(resultMessage())
    await promptPromise

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads).toContainEqual(
      expect.objectContaining({
        content: { text: "Looking at the files now.", type: "text" },
        messageId: "msg-sub-agent-1",
        parentToolCallId: "parent-agent-1",
        sessionUpdate: "agent_message_chunk"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        kind: "execute",
        parentToolCallId: "parent-agent-1",
        sessionUpdate: "tool_call_update",
        title: "Ran ls -la",
        toolCallId: "sub-bash-1"
      })
    )
  })

  it("skips consolidated subagent text when its message already streamed", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("spawn an agent"))
    await settle()
    // Older CLIs stream subagent deltas: message_start registers the id...
    fake.push(streamEvent({ message: { id: "msg-sub-1" }, type: "message_start" }, "parent-1"))
    fake.push(
      streamEvent(
        {
          delta: { text: "streamed text", type: "text_delta" },
          index: 0,
          type: "content_block_delta"
        },
        "parent-1"
      )
    )
    // ...so the consolidated re-send of the same message must not double it.
    fake.push({
      message: {
        content: [{ text: "streamed text", type: "text" }],
        id: "msg-sub-1",
        role: "assistant"
      },
      parent_tool_use_id: "parent-1",
      session_id: "sdk-session-1",
      type: "assistant"
    } as never)
    fake.push(resultMessage())
    await promptPromise

    const chunks = events
      .map((event) => event.payload as Record<string, unknown>)
      .filter(
        (payload) =>
          payload.sessionUpdate === "agent_message_chunk" && payload.parentToolCallId === "parent-1"
      )
    expect(chunks).toHaveLength(1)
  })

  it("retro-tags streamed preamble text as commentary when a tool call starts in the same message", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("check the tests"))
    await settle()
    // Preamble text streams, then a tool_use begins in the same message —
    // the Anthropic stream's earliest proof the text was not the final answer.
    fake.push(streamEvent({ message: { id: "msg-pre" }, type: "message_start" }))
    fake.push(
      streamEvent({
        delta: { text: "Let me check the tests.", type: "text_delta" },
        index: 0,
        type: "content_block_delta"
      })
    )
    fake.push(
      streamEvent({
        content_block: { id: "toolu-1", name: "Bash", type: "tool_use" },
        index: 1,
        type: "content_block_start"
      })
    )
    // A second tool_use with no text in between must not re-tag.
    fake.push(
      streamEvent({
        content_block: { id: "toolu-2", name: "Bash", type: "tool_use" },
        index: 2,
        type: "content_block_start"
      })
    )
    // The final answer arrives as a fresh message: no tool follows, no tag.
    fake.push(streamEvent({ message: { id: "msg-final" }, type: "message_start" }))
    fake.push(
      streamEvent({
        delta: { text: "Tests pass.", type: "text_delta" },
        index: 0,
        type: "content_block_delta"
      })
    )
    fake.push(resultMessage())
    await promptPromise

    const chunks = events
      .map((event) => event.payload as Record<string, unknown>)
      .filter((payload) => payload.sessionUpdate === "agent_message_chunk")
    // Streamed text carries no phase (unknown until proven otherwise)…
    expect(chunks[0]).toMatchObject({
      content: { text: "Let me check the tests.", type: "text" },
      messageId: "msg-pre"
    })
    expect(chunks[0]).not.toHaveProperty("phase")
    // …then exactly one zero-length correction demotes the preamble span.
    const corrections = chunks.filter((payload) => payload.phase === "commentary")
    expect(corrections).toHaveLength(1)
    expect(corrections[0]).toMatchObject({
      content: { text: "", type: "text" },
      messageId: "msg-pre"
    })
    // The fresh final-answer message streams untagged.
    const finalChunk = chunks.find((payload) => payload.messageId === "msg-final")
    expect(finalChunk).toMatchObject({ content: { text: "Tests pass.", type: "text" } })
    expect(finalChunk).not.toHaveProperty("phase")
  })

  it("retitles the spawning tool call from task_started", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    await createPromise

    fake.push(
      systemMessage("task_started", {
        description: "Explore the repo",
        subagent_type: "Explore",
        task_id: "sub-1",
        tool_use_id: "toolu-agent-1"
      })
    )
    // Shell tasks must NOT be retitled as agents.
    fake.push(
      systemMessage("task_started", {
        description: "Run npm test",
        task_id: "bg-1",
        task_type: "shell",
        tool_use_id: "toolu-bash-1"
      })
    )
    await settle()

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads).toContainEqual(
      expect.objectContaining({
        kind: "agent",
        sessionUpdate: "tool_call_update",
        title: "Agent: Explore the repo",
        toolCallId: "toolu-agent-1"
      })
    )
    expect(
      payloads.some(
        (payload) =>
          payload.sessionUpdate === "tool_call_update" && payload.toolCallId === "toolu-bash-1"
      )
    ).toBe(false)
  })

  it("tracks background tasks across the turn boundary and clears on notification", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    // A fresh session emits an empty snapshot so replayed clients start clean.
    const snapshots = () =>
      events
        .filter((event) => event.kind === "session.updated")
        .map((event) => event.payload as Record<string, unknown>)
        .filter((payload) => Array.isArray(payload.backgroundTasks))
        .map((payload) => payload.backgroundTasks as Array<Record<string, unknown>>)
    expect(snapshots()).toContainEqual([])

    const promptPromise = run(created.handle.prompt("run tests in the background"))
    await settle()
    fake.push(
      systemMessage("task_started", {
        description: "Run npm test",
        task_id: "bg-1",
        task_type: "shell",
        tool_use_id: "tool-bash-1"
      })
    )
    fake.push(resultMessage())
    await promptPromise
    await settle()

    // The task survives turn end — that is what the waiting indicator keys on.
    const afterTurn = snapshots().at(-1)
    expect(afterTurn).toEqual([
      {
        description: "Run npm test",
        id: "bg-1",
        status: "running",
        taskType: "shell",
        toolUseId: "tool-bash-1"
      }
    ])

    fake.push(
      systemMessage("task_notification", {
        output_file: "/tmp/out.txt",
        status: "completed",
        summary: "tests passed",
        task_id: "bg-1"
      })
    )
    await settle()
    expect(snapshots().at(-1)).toEqual([])
  })

  it("rewrites background Bash through the terminal wrapper and stamps terminalKey", async () => {
    const fake = new FakeQuery()
    const provider = makeClaudeProvider(environment, {
      backgroundTerminals: {
        registry: { register: () => ({ exit: () => {}, output: () => {}, remove: () => {} }) },
        wrapCommand: (key, command) => `bg-wrap ${key} :: ${command}`
      },
      checkVersion: async () => "2.1.0",
      queryFn: (input) => {
        fake.options = input.options
        return fake as never
      }
    })
    const events: Array<RuntimeEvent> = []
    const createPromise = run(
      provider.createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    await settle()
    fake.push(initMessage())
    const created = await createPromise
    const sessionKey = created.metadata.sessionId

    const preToolUse = fake.options?.hooks?.PreToolUse?.[0]
    expect(preToolUse?.matcher).toBe("Bash")
    const hook = preToolUse?.hooks[0]
    expect(hook).toBeDefined()

    // Background commands are wrapped under a key derived from the tool use.
    const wrapped = await hook?.(
      {
        hook_event_name: "PreToolUse",
        tool_input: { command: "npm run dev", run_in_background: true },
        tool_name: "Bash"
      } as never,
      "tool-bash-9",
      { signal: new AbortController().signal }
    )
    expect((wrapped as { hookSpecificOutput?: unknown } | undefined)?.hookSpecificOutput).toEqual({
      hookEventName: "PreToolUse",
      updatedInput: {
        command: `bg-wrap ${sessionKey}:bg:tool-bash-9 :: npm run dev`,
        run_in_background: true
      }
    })

    // Foreground commands, malformed inputs, and hook calls without a tool
    // use id all pass through untouched.
    const foreground = await hook?.(
      {
        hook_event_name: "PreToolUse",
        tool_input: { command: "ls" },
        tool_name: "Bash"
      } as never,
      "tool-bash-10",
      { signal: new AbortController().signal }
    )
    expect(foreground).toEqual({})
    const malformed = await hook?.(
      { hook_event_name: "PreToolUse", tool_input: "ls", tool_name: "Bash" } as never,
      "tool-bash-11",
      { signal: new AbortController().signal }
    )
    expect(malformed).toEqual({})
    const anonymous = await hook?.(
      {
        hook_event_name: "PreToolUse",
        tool_input: { command: "sleep 99", run_in_background: true },
        tool_name: "Bash"
      } as never,
      undefined,
      { signal: new AbortController().signal }
    )
    expect(anonymous).toEqual({})

    // The task spawned by the wrapped tool use carries the terminal key.
    fake.push(
      systemMessage("task_started", {
        description: "npm run dev",
        task_id: "bg-9",
        task_type: "shell",
        tool_use_id: "tool-bash-9"
      })
    )
    await settle()
    const snapshots = events
      .filter((event) => event.kind === "session.updated")
      .map((event) => event.payload as Record<string, unknown>)
      .filter((payload) => Array.isArray(payload.backgroundTasks))
      .map((payload) => payload.backgroundTasks as Array<Record<string, unknown>>)
    expect(snapshots.at(-1)).toEqual([
      {
        description: "npm run dev",
        id: "bg-9",
        status: "running",
        taskType: "shell",
        terminalKey: `${sessionKey}:bg:tool-bash-9`,
        toolUseId: "tool-bash-9"
      }
    ])

    // Task completion clears the tool-use → key mapping, so a task reusing
    // the tool use id later gets no stale terminal key.
    fake.push(systemMessage("task_updated", { patch: { status: "completed" }, task_id: "bg-9" }))
    fake.push(
      systemMessage("task_started", {
        description: "npm run dev (again)",
        task_id: "bg-10",
        task_type: "shell",
        tool_use_id: "tool-bash-9"
      })
    )
    await settle()
    const latest = events
      .filter((event) => event.kind === "session.updated")
      .map((event) => event.payload as Record<string, unknown>)
      .filter((payload) => Array.isArray(payload.backgroundTasks))
      .map((payload) => payload.backgroundTasks as Array<Record<string, unknown>>)
      .at(-1)
    expect(latest).toEqual([
      {
        description: "npm run dev (again)",
        id: "bg-10",
        status: "running",
        taskType: "shell",
        toolUseId: "tool-bash-9"
      }
    ])
  })

  it("derives subagent taskType, applies patches and hides skip_transcript tasks", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    await createPromise

    fake.push(
      systemMessage("task_started", {
        description: "Explore the codebase",
        subagent_type: "Explore",
        task_id: "sub-1"
      })
    )
    fake.push(
      systemMessage("task_started", {
        description: "Ambient housekeeping",
        skip_transcript: true,
        task_id: "ambient-1"
      })
    )
    fake.push(systemMessage("task_updated", { patch: { status: "paused" }, task_id: "sub-1" }))
    await settle()

    const snapshots = () =>
      events
        .filter((event) => event.kind === "session.updated")
        .map((event) => event.payload as Record<string, unknown>)
        .filter((payload) => Array.isArray(payload.backgroundTasks))
        .map((payload) => payload.backgroundTasks as Array<Record<string, unknown>>)
    expect(snapshots().at(-1)).toEqual([
      {
        description: "Explore the codebase",
        id: "sub-1",
        status: "paused",
        taskType: "subagent"
      }
    ])
    expect(snapshots().every((snapshot) => snapshot.every((task) => task.id !== "ambient-1"))).toBe(
      true
    )

    fake.push(systemMessage("task_updated", { patch: { status: "killed" }, task_id: "sub-1" }))
    await settle()
    expect(snapshots().at(-1)).toEqual([])
  })

  it("emits authoritative diff stats and content from the PostToolUse hook", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise
    void created

    const hooks = fake.options?.hooks?.PostToolUse?.[0]?.hooks
    expect(hooks).toBeDefined()
    await hooks?.[0]?.(
      {
        cwd: "/tmp",
        hook_event_name: "PostToolUse",
        session_id: "sdk-session-1",
        tool_input: { file_path: "/tmp/a.txt", new_string: "x\ny\n", old_string: "z\n" },
        tool_name: "Edit",
        tool_response: {
          structuredPatch: [
            { lines: ["-z", "+x", "+y"], newLines: 2, newStart: 1, oldLines: 1, oldStart: 1 }
          ]
        },
        tool_use_id: "tool-hook-1",
        transcript_path: "/tmp/transcript"
      } as never,
      "tool-hook-1",
      { signal: new AbortController().signal }
    )
    await settle()

    const payload = events.at(-1)?.payload as Record<string, unknown>
    expect(payload).toMatchObject({
      sessionUpdate: "tool_call_update",
      toolCallId: "tool-hook-1",
      diffStats: [{ added: 2, path: "/tmp/a.txt", removed: 1 }]
    })
    expect(payload.content).toEqual([
      { newText: "x\ny\n", oldText: "z\n", path: "/tmp/a.txt", type: "diff" }
    ])
  })

  it("recomputes stats for a Write creation whose structuredPatch is empty", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    await createPromise

    // The SDK reports file creations with an empty structuredPatch — there
    // was nothing to patch. Counting its hunks yields an authoritative
    // +0 −0 that used to beat the content-derived totals in the client.
    const hooks = fake.options?.hooks?.PostToolUse?.[0]?.hooks
    expect(hooks).toBeDefined()
    await hooks?.[0]?.(
      {
        cwd: "/tmp",
        hook_event_name: "PostToolUse",
        session_id: "sdk-session-1",
        tool_input: { content: "a\nb\nc\n", file_path: "/tmp/new.py" },
        tool_name: "Write",
        tool_response: { structuredPatch: [], type: "create" },
        tool_use_id: "tool-hook-2",
        transcript_path: "/tmp/transcript"
      } as never,
      "tool-hook-2",
      { signal: new AbortController().signal }
    )
    await settle()

    const payload = events.at(-1)?.payload as Record<string, unknown>
    expect(payload).toMatchObject({
      sessionUpdate: "tool_call_update",
      toolCallId: "tool-hook-2",
      diffStats: [{ added: 3, path: "/tmp/new.py", removed: 0 }]
    })
    expect(payload.content).toEqual([
      { newText: "a\nb\nc\n", oldText: null, path: "/tmp/new.py", type: "diff" }
    ])
  })

  it("resumes sessions under the requested id", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const loadPromise = run(
      provider.loadSession(definition, "previous-session", "/tmp", async () => undefined)
    )
    await settle()
    fake.push(initMessage("sdk-session-resumed"))
    const loaded = await loadPromise
    expect(loaded.sessionId).toBe("previous-session")
    expect(loaded.metadata?.sessionId).toBe("previous-session")
    expect(loaded.metadata?.configOptions.length).toBeGreaterThan(0)
    expect(fake.options?.resume).toBe("previous-session")
  })

  it("maps attachments: inline images and PDFs, with path notes for every attachment", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const createPromise = run(provider.createSession(definition, "/tmp", async () => undefined))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(
      created.handle.prompt({
        text: "look at these",
        attachments: [
          {
            data: Buffer.from("png-bytes"),
            kind: "image",
            mimeType: "image/png",
            name: "shot.png",
            path: "/tmp/att/shot.png"
          },
          {
            data: Buffer.from("pdf-bytes"),
            kind: "file",
            mimeType: "application/pdf",
            name: "doc.pdf",
            path: "/tmp/att/doc.pdf"
          },
          {
            data: Buffer.from("plain"),
            kind: "file",
            mimeType: "text/plain",
            name: "notes.txt",
            path: "/tmp/att/notes.txt"
          },
          {
            data: Buffer.from("heic-bytes"),
            kind: "image",
            mimeType: "image/heic",
            name: "raw.heic",
            path: "/tmp/att/raw.heic"
          }
        ]
      })
    )
    await settle()
    expect(fake.userMessages[0]?.message.content).toEqual([
      {
        text: [
          "look at these",
          "[Attached file: /tmp/att/shot.png (shot.png, image/png)]",
          "[Attached file: /tmp/att/doc.pdf (doc.pdf, application/pdf)]",
          "[Attached file: /tmp/att/notes.txt (notes.txt, text/plain)]",
          "[Attached file: /tmp/att/raw.heic (raw.heic, image/heic)]"
        ].join("\n\n"),
        type: "text"
      },
      {
        source: {
          data: Buffer.from("png-bytes").toString("base64"),
          media_type: "image/png",
          type: "base64"
        },
        type: "image"
      },
      {
        source: {
          data: Buffer.from("pdf-bytes").toString("base64"),
          media_type: "application/pdf",
          type: "base64"
        },
        type: "document"
      }
    ])
    fake.push(resultMessage())
    await promptPromise
  })

  it("notes the temp-file path even for an image-only prompt", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const createPromise = run(provider.createSession(definition, "/tmp", async () => undefined))
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(
      created.handle.prompt({
        text: "",
        attachments: [
          {
            data: Buffer.from("img"),
            kind: "image",
            mimeType: "image/jpeg",
            name: "a.jpg",
            path: "/tmp/att/a.jpg"
          }
        ]
      })
    )
    await settle()
    expect(fake.userMessages[0]?.message.content).toEqual([
      {
        text: "[Attached file: /tmp/att/a.jpg (a.jpg, image/jpeg)]",
        type: "text"
      },
      {
        source: {
          data: Buffer.from("img").toString("base64"),
          media_type: "image/jpeg",
          type: "base64"
        },
        type: "image"
      }
    ])
    fake.push(resultMessage())
    await promptPromise
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

describe("partial JSON string extraction", () => {
  it("extracts complete and streaming values", () => {
    const complete = '{"file_path":"/a.txt","old_string":"one\\ntwo"}'
    expect(extractStringField(complete, "file_path")).toBe("/a.txt")
    expect(extractStringField(complete, "old_string")).toBe("one\ntwo")

    const partial = '{"file_path":"/a.txt","new_string":"line one\\nline tw'
    expect(extractStringField(partial, "new_string")).toBe("line one\nline tw")
    expect(extractStringField(partial, "missing")).toBeUndefined()
  })

  it("decodes escapes including unicode", () => {
    const json = '{"s":"tab\\there \\u0041 quote\\" done"}'
    expect(extractStringField(json, "s")).toBe('tab\there A quote" done')
  })

  it("extracts every occurrence for MultiEdit", () => {
    const json =
      '{"edits":[{"old_string":"a\\nb","new_string":"c"},{"old_string":"d","new_string":"e\\nf"}]}'
    expect(extractAllStringFields(json, "old_string")).toEqual(["a\nb", "d"])
    expect(extractAllStringFields(json, "new_string")).toEqual(["c", "e\nf"])
  })
})

describe("webSearchSources", () => {
  it("parses the Links array from a WebSearch result string", () => {
    const result =
      'Web search results for query: "swift release"\n\n' +
      'Links: [{"title":"A","url":"https://a.example"},{"title":"B","url":"https://b.example"}]\n\n' +
      "Some commentary."
    expect(webSearchSources(result)).toEqual([
      { title: "A", url: "https://a.example" },
      { title: "B", url: "https://b.example" }
    ])
  })

  it("reads the text out of a block array result", () => {
    const blocks = [
      {
        text: 'Web search results for query: "x"\n\nLinks: [{"title":"A","url":"https://a"}]',
        type: "text"
      }
    ]
    expect(webSearchSources(blocks)).toEqual([{ title: "A", url: "https://a" }])
  })

  it("isolates the array even when a title contains brackets", () => {
    const result =
      'Web search results for query: "x"\n\n' +
      'Links: [{"title":"Array [T] docs","url":"https://a"}]\n\nend'
    expect(webSearchSources(result)).toEqual([{ title: "Array [T] docs", url: "https://a" }])
  })

  it("returns [] for non-search results and malformed links", () => {
    expect(webSearchSources("total 0\n-rw-r--r-- file.txt")).toEqual([])
    expect(webSearchSources('Links: [{"title":"A","url":"https://a"}]')).toEqual([])
    expect(webSearchSources('Web search results for query: "x"\n\nLinks: [not json')).toEqual([])
    expect(webSearchSources(undefined)).toEqual([])
  })
})

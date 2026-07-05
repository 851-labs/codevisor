import type {
  Options as ClaudeOptions,
  SDKMessage,
  SDKUserMessage
} from "@anthropic-ai/claude-agent-sdk"
import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { HarnessDefinition, ProviderEnvironment, RuntimeEvent } from "../types.js"
import { extractAllStringFields, extractStringField, makeClaudeProvider } from "./claude.js"

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

const initMessage = (sessionId = "sdk-session-1"): SDKMessage =>
  ({
    apiKeySource: "none",
    cwd: "/tmp",
    model: "claude-fable-5",
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

const makeProvider = (fake: FakeQuery, checkVersion = async () => "2.1.0") =>
  makeClaudeProvider(environment, {
    checkVersion,
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
    expect(created.metadata.modes?.currentModeId).toBe("default")
    expect(created.metadata.modes?.availableModes.find((mode) => mode.id === "default")?.name).toBe(
      "Always Ask"
    )
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
    expect(fake.options?.resume).toBe("previous-session")
  })

  it("maps attachments: inline images and PDFs, path notes for everything else", async () => {
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

  it("omits the text block for an image-only prompt", async () => {
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

import { afterEach, describe, expect, it, vi } from "vitest"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  resultMessage,
  run,
  settle,
  streamEvent
} from "./test-support.js"

describe("ClaudeProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
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
})

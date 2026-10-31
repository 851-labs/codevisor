import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { afterEach, describe, expect, it, vi } from "vitest"

import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  payloadOf,
  rateLimitEvent,
  resultMessage,
  resultWith,
  run,
  sdkMessage,
  startTestSession,
  streamEvent,
  systemMessage,
  turnPayloads
} from "./test-support.js"

describe("ClaudeProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("emits the SDK-generated title after a completed turn", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(
      fake,
      async () => "2.1.0",
      async () => ({
        customTitle: "Harness title",
        lastModified: 0,
        sessionId: "sdk-session-1",
        summary: "Generated"
      })
    )
    const events: RuntimeEvent[] = []
    const createPromise = run(
      provider.createSession(definition, "/tmp", async (event) => {
        events.push(event)
      })
    )
    fake.push(initMessage())
    const created = await createPromise
    const prompt = run(created.handle.prompt("hello"))
    await fake.nextPrompt()
    fake.push(resultMessage())
    await prompt
    await fake.drain()

    expect(events.map((event) => event.payload)).toContainEqual({
      sessionUpdate: "session_info_update",
      title: "Harness title"
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
    await fake.drain()

    const payloads = turnPayloads(events)
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

  it("does not end a user turn when a task-notification result interleaves", async () => {
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

    let promptResolved = false
    const prompt = run(created.handle.prompt("wait for everything")).then((result) => {
      promptResolved = true
      return result
    })
    await fake.drain()
    fake.push(sdkMessage({ ...resultMessage(), origin: { kind: "task-notification" } }))
    await fake.drain()
    expect(promptResolved).toBe(false)
    expect(events.filter((event) => payloadOf(event).turnState === "ended")).toHaveLength(0)

    fake.push(resultMessage())
    await prompt
    expect(promptResolved).toBe(true)
    expect(events.filter((event) => payloadOf(event).turnState === "ended")).toHaveLength(1)
  })

  it.each(["streamed", "complete"])(
    "finishes a %s reply at idle with only a task-notification result",
    async (delivery) => {
      const { fake, created, events } = await startTestSession()
      if (delivery === "complete") {
        await run(created.handle.setGoal!({ objective: "finish the change" }))
        await fake.nextPrompt()
      }
      let completed = false
      const prompt = run(created.handle.prompt("finish the change")).then(() => {
        completed = true
      })
      await fake.nextPrompt()

      if (delivery === "streamed") {
        fake.push(streamEvent({ message: { id: "msg-final" }, type: "message_start" }))
        fake.push(streamEvent({ delta: { stop_reason: "end_turn" }, type: "message_delta" }))
      }
      fake.push(
        sdkMessage({
          type: "assistant",
          parent_tool_use_id: null,
          message: {
            id: "msg-final",
            role: "assistant",
            content: [{ type: "text", text: "Finished the change." }],
            stop_reason: delivery === "complete" ? "end_turn" : null
          }
        })
      )
      fake.push(sdkMessage({ ...resultMessage(), origin: { kind: "task-notification" } }))
      fake.push(systemMessage("session_state_changed", { state: "requires_action" }))
      await fake.drain()
      expect(completed).toBe(false)

      fake.push(systemMessage("session_state_changed", { state: "idle" }))
      await fake.drain()
      expect(
        events.map(payloadOf).filter((payload) => payload.turnState === "ended")
      ).toMatchObject([{ initiatedBy: "user", stopReason: "end_turn" }])
      await prompt
      if (delivery === "complete") {
        const goals = events.map(payloadOf).filter((payload) => payload.goal !== undefined)
        expect(goals.at(-1)).toMatchObject({ goal: { status: "complete" } })
      }
      await run(created.handle.close)
    }
  )

  it("ignores a premature background completion", async () => {
    const { fake, created, events } = await startTestSession()
    const prompt = run(created.handle.prompt("new request"))
    await fake.nextPrompt()

    fake.push(sdkMessage({ ...resultMessage(), origin: { kind: "task-notification" } }))
    fake.push(systemMessage("session_state_changed", { state: "idle" }))
    await fake.drain()
    expect(events.map(payloadOf).filter((payload) => payload.turnState === "ended")).toHaveLength(0)
    expect(events.map(payloadOf).filter((payload) => payload.retrying !== undefined)).toHaveLength(
      0
    )

    fake.push(resultMessage())
    await prompt
    await run(created.handle.close)
  })

  it("retries a failed background result at idle like the turn's own result", async () => {
    vi.useFakeTimers()
    const { fake, created, events } = await startTestSession()
    const prompt = run(created.handle.prompt("new request"))
    await fake.nextPrompt()
    const continuations = () =>
      fake.userMessages.filter((message) => message.message.content === "Please continue.")

    fake.push(streamEvent({ message: { id: "msg-final" }, type: "message_start" }))
    fake.push(streamEvent({ delta: { stop_reason: "end_turn" }, type: "message_delta" }))
    fake.push(
      sdkMessage({
        ...resultMessage("error_during_execution"),
        origin: { kind: "task-notification" }
      })
    )
    await fake.drain()
    expect(events.map(payloadOf).filter((payload) => payload.retrying !== undefined)).toHaveLength(
      0
    )

    fake.push(systemMessage("session_state_changed", { state: "idle" }))
    await fake.drain()
    expect(events.map(payloadOf).filter((payload) => payload.retrying !== undefined)).toMatchObject(
      [{ retrying: { attempt: 1, of: 3 } }]
    )
    await vi.advanceTimersByTimeAsync(999)
    expect(continuations()).toHaveLength(0)
    await vi.advanceTimersByTimeAsync(1)
    await fake.drain()
    expect(continuations()).toHaveLength(1)
    expect(events.map(payloadOf).filter((payload) => payload.turnState === "ended")).toHaveLength(0)

    fake.push(resultMessage())
    await prompt
    await run(created.handle.close)
  })

  it("ends the turn at a usage limit when Claude folds the prompt into a background-task query", async () => {
    const { fake, created, events } = await startTestSession()
    let completed = false
    const prompt = run(created.handle.prompt("Yes, resume. Keep going.")).then(() => {
      completed = true
    })
    await fake.nextPrompt()

    fake.push(
      sdkMessage({
        type: "assistant",
        parent_tool_use_id: null,
        message: {
          id: "msg-check",
          role: "assistant",
          content: [
            { type: "text", text: "The run finished. Checking its result." },
            { type: "tool_use", id: "toolu-check", name: "Bash", input: { command: "gh run view" } }
          ],
          stop_reason: "tool_use"
        }
      })
    )
    fake.push(
      sdkMessage({
        type: "user",
        parent_tool_use_id: null,
        message: {
          role: "user",
          content: [{ type: "tool_result", tool_use_id: "toolu-check", content: "success" }]
        }
      })
    )
    fake.push(
      rateLimitEvent({ rateLimitType: "five_hour", resetsAt: 1_761_001_200, status: "rejected" })
    )
    const limitText = "You've hit your 5-hour limit · resets 4pm (America/Los_Angeles)"
    fake.push(
      sdkMessage({
        type: "assistant",
        error: "rate_limit",
        parent_tool_use_id: null,
        message: {
          id: "msg-limit",
          role: "assistant",
          content: [{ type: "text", text: limitText }],
          stop_reason: "stop_sequence"
        }
      })
    )
    fake.push(
      sdkMessage({
        ...resultWith({ is_error: true, result: limitText, stop_reason: "stop_sequence" }),
        origin: { kind: "task-notification" }
      })
    )
    await fake.drain()
    expect(completed).toBe(false)

    fake.push(systemMessage("session_state_changed", { state: "idle" }))
    await prompt
    expect(events.map(payloadOf).filter((payload) => payload.turnState === "ended")).toMatchObject([
      {
        initiatedBy: "user",
        resetsAt: "2025-10-20T23:00:00.000Z",
        stopDetail: limitText,
        stopKind: "usageLimit",
        stopReason: "end_turn"
      }
    ])
    await run(created.handle.close)
  })

  it("discards a deferred background result when the user result arrives before idle", async () => {
    const { fake, created, events } = await startTestSession()
    const prompt = run(created.handle.prompt("finish the change"))
    await fake.nextPrompt()
    fake.push(sdkMessage({ ...resultMessage(), origin: { kind: "task-notification" } }))
    fake.push(resultMessage())
    await prompt

    const next = run(created.handle.prompt("next change"))
    await fake.nextPrompt()
    fake.push(systemMessage("session_state_changed", { state: "idle" }))
    await fake.drain()
    expect(events.map(payloadOf).filter((payload) => payload.turnState === "ended")).toHaveLength(1)

    fake.push(resultMessage())
    await next
    await run(created.handle.close)
  })

  it("defers a prompt sent during an agent-initiated turn until that turn ends", async () => {
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

    fake.push(streamEvent({ message: { id: "msg-bg" }, type: "message_start" }))
    fake.push(
      streamEvent({
        delta: { text: "Task finished, wrapping up.", type: "text_delta" },
        index: 0,
        type: "content_block_delta"
      })
    )
    await fake.drain()

    let promptResolved = false
    const prompt = run(created.handle.prompt("follow-up")).then((result) => {
      promptResolved = true
      return result
    })
    await fake.drain()
    expect(fake.userMessages).toHaveLength(0)

    fake.push(sdkMessage({ ...resultMessage(), origin: { kind: "task-notification" } }))
    await fake.drain()
    expect(promptResolved).toBe(false)
    const turnEvents = events.map(payloadOf).filter((payload) => payload.turnState !== undefined)
    expect(turnEvents).toMatchObject([
      { initiatedBy: "agent", turnState: "started" },
      { initiatedBy: "agent", turnState: "ended" },
      { initiatedBy: "user", turnState: "started" }
    ])
    expect(fake.userMessages).toHaveLength(1)

    fake.push(resultMessage())
    await prompt
    expect(promptResolved).toBe(true)
    expect(events.filter((event) => payloadOf(event).turnState === "ended")).toHaveLength(2)
  })
})

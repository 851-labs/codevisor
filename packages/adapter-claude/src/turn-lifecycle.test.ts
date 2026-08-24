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

  it("does not end a user turn when a task-notification result interleaves", async () => {
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

    let promptResolved = false
    const prompt = run(created.handle.prompt("wait for everything")).then((result) => {
      promptResolved = true
      return result
    })
    await settle()
    fake.push({ ...resultMessage(), origin: { kind: "task-notification" } } as never)
    await settle()
    expect(promptResolved).toBe(false)
    expect(
      events.filter((event) => (event.payload as Record<string, unknown>).turnState === "ended")
    ).toHaveLength(0)

    fake.push(resultMessage())
    await prompt
    expect(promptResolved).toBe(true)
    expect(
      events.filter((event) => (event.payload as Record<string, unknown>).turnState === "ended")
    ).toHaveLength(1)
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
    await settle()
    fake.push(initMessage())
    const created = await createPromise

    // The harness re-triggered itself off a finished background task: output
    // begins with no prompt in flight, opening an agent-initiated turn.
    fake.push(streamEvent({ message: { id: "msg-bg" }, type: "message_start" }))
    fake.push(
      streamEvent({
        delta: { text: "Task finished, wrapping up.", type: "text_delta" },
        index: 0,
        type: "content_block_delta"
      })
    )
    await settle()

    // A user prompt lands mid-turn. It must neither bind to the live agent
    // turn (whose result would resolve it prematurely) nor be pushed into it.
    let promptResolved = false
    const prompt = run(created.handle.prompt("follow-up")).then((result) => {
      promptResolved = true
      return result
    })
    await settle()
    expect(fake.userMessages).toHaveLength(0)

    // The agent turn's own result closes only the agent turn, then the
    // deferred prompt dispatches as its own user-initiated turn.
    fake.push({ ...resultMessage(), origin: { kind: "task-notification" } } as never)
    await settle()
    expect(promptResolved).toBe(false)
    const turnEvents = events
      .map((event) => event.payload as Record<string, unknown>)
      .filter((payload) => payload.turnState !== undefined)
    expect(turnEvents).toMatchObject([
      { initiatedBy: "agent", turnState: "started" },
      { initiatedBy: "agent", turnState: "ended" },
      { initiatedBy: "user", turnState: "started" }
    ])
    expect(fake.userMessages).toHaveLength(1)

    fake.push(resultMessage())
    await prompt
    expect(promptResolved).toBe(true)
    expect(
      events.filter((event) => (event.payload as Record<string, unknown>).turnState === "ended")
    ).toHaveLength(2)
  })
})

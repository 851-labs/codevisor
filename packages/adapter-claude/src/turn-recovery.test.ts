import { afterEach, describe, expect, it, vi } from "vitest"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import {
  assistantApiErrorMessage,
  assistantErrorMessage,
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  resultMessage,
  resultWith,
  run,
  settle,
  streamEvent
} from "./test-support.js"

describe("ClaudeProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
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

    // Backoff: not resumed yet and the turn stays alive, but the reason is
    // already visible to the client.
    expect(continuations()).toHaveLength(0)
    expect(endedEvents()).toHaveLength(0)
    expect(events.some((event) => event.kind === "session.error")).toBe(false)
    expect(events.at(-1)).toMatchObject({
      kind: "session.updated",
      payload: {
        retrying: {
          attempt: 1,
          message: "Claude is still overloaded, restarting response",
          of: 3
        }
      }
    })

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
      expect(retryingEvents().at(-1)).toMatchObject({
        payload: {
          retrying: {
            attempt,
            message: "Claude is still overloaded, restarting response",
            of: 3
          }
        }
      })
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
})

import { afterEach, describe, expect, it, vi } from "vitest"

import {
  assistantApiErrorMessage,
  assistantErrorMessage,
  payloadOf,
  resultMessage,
  resultWith,
  run,
  sdkMessage,
  startTestSession,
  streamEvent,
  systemMessage
} from "./test-support.js"

const authRetry = (attempt: number) =>
  systemMessage("api_retry", {
    attempt,
    error: "authentication_failed",
    error_status: 401,
    max_retries: 10,
    retry_delay_ms: 500
  })

describe("ClaudeProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("auto-continues a turn truncated by the output-token cap, then ends on the next result", async () => {
    const { fake, events, created } = await startTestSession()

    const promptPromise = run(created.handle.prompt("write a very long file"))
    await fake.nextPrompt()
    expect(fake.userMessages).toHaveLength(1)

    fake.push(streamEvent({ message: { id: "msg-1" }, type: "message_start" }))
    fake.push(
      streamEvent({
        delta: { text: "Working…", type: "text_delta" },
        index: 0,
        type: "content_block_delta"
      })
    )
    await fake.drain()
    fake.push(resultWith({ stop_reason: "max_tokens" }))
    await fake.drain()

    const endedEvents = () =>
      events.filter(
        (event) => event.kind === "session.updated" && payloadOf(event).turnState === "ended"
      )
    const continuations = () =>
      fake.userMessages.filter((message) => message.message.content === "Please continue.")

    expect(continuations()).toHaveLength(1)
    expect(endedEvents()).toHaveLength(0)

    fake.push(resultWith({ stop_reason: "end_turn" }))
    const result = await promptPromise
    expect(result.stopReason).toBe("end_turn")
    expect(endedEvents()).toHaveLength(1)
  })

  it("stops auto-continuing once the per-turn continuation budget is exhausted", async () => {
    const { fake, created } = await startTestSession()

    const promptPromise = run(created.handle.prompt("keep truncating"))
    await fake.nextPrompt()

    for (let index = 0; index < 13; index += 1) {
      fake.push(resultWith({ stop_reason: "max_tokens" }))
      await fake.drain()
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
    const { fake, events, created } = await startTestSession()

    const promptPromise = run(created.handle.prompt("do work"))
    await fake.nextPrompt()
    expect(fake.userMessages).toHaveLength(1)

    fake.push(assistantErrorMessage("overloaded"))
    fake.push(resultMessage("error_during_execution"))
    await fake.drain()

    const continuations = () =>
      fake.userMessages.filter((message) => message.message.content === "Please continue.")
    const endedEvents = () =>
      events.filter(
        (event) => event.kind === "session.updated" && payloadOf(event).turnState === "ended"
      )

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

    await vi.advanceTimersByTimeAsync(1000)
    await fake.drain()
    expect(continuations()).toHaveLength(1)
    expect(endedEvents()).toHaveLength(0)

    fake.push(resultMessage("success"))
    await fake.drain()
    const result = await promptPromise
    expect(result.stopReason).toBe("end_turn")
    expect(endedEvents()).toHaveLength(1)
    expect(events.some((event) => event.kind === "session.error")).toBe(false)
  })

  it("retries a 529 that arrives as text (no structured error), then surfaces it", async () => {
    vi.useFakeTimers()
    const { fake, events, created } = await startTestSession()

    const promptPromise = run(created.handle.prompt("do work"))
    await fake.nextPrompt()

    const errorText = "API Error: 529 Overloaded. This is a server-side issue; please retry."
    const continuations = () =>
      fake.userMessages.filter((message) => message.message.content === "Please continue.")
    const retryingEvents = () =>
      events.filter(
        (event) => event.kind === "session.updated" && payloadOf(event).retrying !== undefined
      )
    const endedEvents = () =>
      events.filter(
        (event) => event.kind === "session.updated" && payloadOf(event).turnState === "ended"
      )

    for (let attempt = 1; attempt <= 3; attempt += 1) {
      fake.push(assistantApiErrorMessage(errorText))
      fake.push(resultMessage("success"))
      await fake.drain()
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
      await fake.drain()
      expect(continuations()).toHaveLength(attempt)
    }

    fake.push(assistantApiErrorMessage(errorText))
    fake.push(resultMessage("success"))
    await fake.drain()
    const result = await promptPromise
    expect(result.stopReason).toBe("end_turn")
    const endedPayload = events.map(payloadOf).find((payload) => payload.turnState === "ended")
    expect(endedPayload?.stopDetail).toBe(errorText)
    expect(endedPayload?.retryable).toBe(true)
    expect(endedPayload?.stopKind).toBe("harnessFailed")
    expect(retryingEvents()).toHaveLength(3)
  })

  it.each(["success", "error_during_execution"] as const)(
    "surfaces a permanent API error immediately, despite a %s result",
    async (subtype) => {
      const { fake, events, created } = await startTestSession()

      const promptPromise = run(created.handle.prompt("do work"))
      await fake.nextPrompt()

      fake.push(assistantErrorMessage("model_not_found"))
      fake.push(resultMessage(subtype))
      const result = await promptPromise
      expect(result.stopReason).toBe("end_turn")

      expect(
        fake.userMessages.filter((message) => message.message.content === "Please continue.")
      ).toHaveLength(0)
      const endedPayload = events.map(payloadOf).find((payload) => payload.turnState === "ended")
      expect(endedPayload?.stopDetail).toBe("The selected model is unavailable.")
      expect(endedPayload?.stopKind).toBe("harnessFailed")
      expect(events.some((event) => event.kind === "session.error")).toBe(false)
    }
  )

  it("ends a 403 organization rejection as forbidden, with Claude's reason, despite a successful result", async () => {
    const { fake, events, created } = await startTestSession()
    const promptPromise = run(created.handle.prompt("hello"))
    await fake.nextPrompt()

    const detail =
      "Your organization has disabled Claude subscription access for Claude Code · Use an Anthropic API key instead, or ask your admin to enable access"
    fake.push(sdkMessage({ ...assistantApiErrorMessage(detail), error: "oauth_org_not_allowed" }))
    fake.push(
      sdkMessage({ ...resultWith({ is_error: true, result: detail }), api_error_status: 403 })
    )
    await promptPromise

    expect(events.map(payloadOf).find((payload) => payload.turnState === "ended")).toMatchObject({
      stopReason: "end_turn",
      stopKind: "forbidden",
      stopDetail: detail
    })
    expect(fake.userMessages).toHaveLength(1)
    expect(events.some((event) => payloadOf(event).retrying !== undefined)).toBe(false)
  })

  it("ends a signed-out turn as needing sign-in", async () => {
    const { fake, events, created } = await startTestSession()

    const promptPromise = run(created.handle.prompt("do work"))
    await fake.nextPrompt()

    fake.push(assistantErrorMessage("authentication_failed"))
    fake.push(resultWith({ is_error: true, result: "Not logged in · Please run /login" }))
    const result = await promptPromise
    expect(result.stopReason).toBe("end_turn")

    expect(
      fake.userMessages.filter((message) => message.message.content === "Please continue.")
    ).toHaveLength(0)
    const endedPayload = events.map(payloadOf).find((payload) => payload.turnState === "ended")
    expect(endedPayload?.stopDetail).toBe("Claude isn't signed in. Sign in to continue.")
    expect(endedPayload?.stopKind).toBe("authRequired")
    expect(endedPayload?.retryable).toBeUndefined()
    expect(events.some((event) => event.kind === "session.authRequired")).toBe(false)
  })

  it("stops Claude's own sign-in retries and ends the turn as needing sign-in", async () => {
    const { fake, events, created } = await startTestSession()

    const promptPromise = run(created.handle.prompt("do work"))
    await fake.nextPrompt()
    fake.push(authRetry(1))
    fake.push(authRetry(2))
    await fake.drain()
    expect(fake.interrupts).toHaveLength(1)

    fake.push(resultMessage("error_during_execution"))
    const result = await promptPromise
    expect(result.stopReason).toBe("end_turn")
    const payloads = events.map(payloadOf)
    expect(payloads.some((payload) => payload.retrying !== undefined)).toBe(false)
    expect(payloads.find((payload) => payload.turnState === "ended")).toMatchObject({
      stopDetail: "Claude isn't signed in. Sign in to continue.",
      stopKind: "authRequired"
    })
  })

  it("doesn't resume a transient-error turn after the session closes", async () => {
    vi.useFakeTimers()
    const { fake, created } = await startTestSession()

    void run(created.handle.prompt("do work"))
    await fake.drain()

    fake.push(assistantErrorMessage("overloaded"))
    fake.push(resultMessage("error_during_execution"))
    await fake.drain()
    const continuations = () =>
      fake.userMessages.filter((message) => message.message.content === "Please continue.")
    expect(continuations()).toHaveLength(0)

    await run(created.handle.close)
    await vi.advanceTimersByTimeAsync(8000)
    await fake.drain()
    expect(continuations()).toHaveLength(0)
  })

  it("logs each turn-end decision when debug logging is on", async () => {
    vi.useFakeTimers()
    vi.stubEnv("CODEVISOR_DEBUG", "1")
    const logged: Array<string> = []
    const errorSpy = vi.spyOn(console, "error").mockImplementation((line: unknown) => {
      logged.push(String(line))
    })
    try {
      const { fake, created } = await startTestSession()
      const promptPromise = run(created.handle.prompt("do work"))
      await fake.nextPrompt()

      fake.push(resultWith({ stop_reason: "max_tokens" }))
      fake.push(assistantErrorMessage("rate_limit"))
      fake.push(resultMessage("error_during_execution"))
      await fake.drain()
      await vi.advanceTimersByTimeAsync(1000)
      fake.push(resultWith({ stop_reason: "refusal" }))
      await promptPromise
    } finally {
      errorSpy.mockRestore()
      vi.unstubAllEnvs()
    }

    expect(logged.filter((line) => line.startsWith("[claude] turn-end"))).toEqual([
      "[claude] turn-end subtype=success stop_reason=max_tokens terminal=- lastError=- trunc=0 retries=0 -> continue",
      "[claude] turn-end subtype=error_during_execution stop_reason=- terminal=- lastError=rate_limit trunc=1 retries=0 -> retry#1(1000ms)",
      "[claude] turn-end subtype=success stop_reason=refusal terminal=- lastError=- trunc=1 retries=1 -> end/end_turn — Claude declined to respond."
    ])
  })

  it("words a rate-limited or server-error restart", async () => {
    vi.useFakeTimers()
    const { fake, events, created } = await startTestSession()
    const promptPromise = run(created.handle.prompt("do work"))
    await fake.nextPrompt()

    fake.push(assistantErrorMessage("rate_limit"))
    fake.push(resultMessage("error_during_execution"))
    await fake.drain()
    await vi.advanceTimersByTimeAsync(1000)
    fake.push(assistantErrorMessage("server_error"))
    fake.push(resultMessage("error_during_execution"))
    await fake.drain()
    await vi.advanceTimersByTimeAsync(2000)
    fake.push(resultMessage("success"))
    await promptPromise

    const retrying = events
      .map(payloadOf)
      .flatMap((payload) => (payload.retrying === undefined ? [] : [payload.retrying]))
    expect(retrying).toEqual([
      { attempt: 1, message: "Claude is temporarily rate limited, restarting response", of: 3 },
      { attempt: 2, message: "Claude returned a server error, restarting response", of: 3 }
    ])
  })
})

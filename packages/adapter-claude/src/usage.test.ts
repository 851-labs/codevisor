import { afterEach, describe, expect, it, vi } from "vitest"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { claudeUsageLimitsFrom } from "./claude.js"
import {
  assistantErrorMessage,
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  rateLimitEvent,
  resultMessage,
  resultWith,
  run,
  settle
} from "./test-support.js"

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

describe("ClaudeProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
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

  it("stops immediately with Claude's usage-limit message instead of retrying", async () => {
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

    const promptPromise = run(created.handle.prompt("do work"))
    await settle()

    const limitMessage = "You've hit your limit · resets 8pm"
    fake.push(assistantErrorMessage("rate_limit"))
    fake.push(
      resultWith({
        is_error: true,
        result: limitMessage
      })
    )

    const result = await promptPromise
    expect(result.stopReason).toBe("end_turn")
    expect(
      fake.userMessages.filter((message) => message.message.content === "Please continue.")
    ).toHaveLength(0)
    expect(
      events.filter(
        (event) =>
          event.kind === "session.updated" &&
          (event.payload as Record<string, unknown>).retrying !== undefined
      )
    ).toHaveLength(0)
    const endedPayload = events
      .map((event) => event.payload as Record<string, unknown>)
      .find((payload) => payload.turnState === "ended")
    expect(endedPayload?.stopDetail).toBe(limitMessage)
    expect(endedPayload?.retryable).toBeUndefined()
  })

  it("uses rejected Claude subscription state when the result omits limit copy", async () => {
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

    const promptPromise = run(created.handle.prompt("do work"))
    await settle()
    fake.push(
      rateLimitEvent({
        rateLimitType: "five_hour",
        status: "rejected"
      })
    )
    fake.push(assistantErrorMessage("rate_limit"))
    fake.push(resultMessage("error_during_execution"))

    await promptPromise
    expect(
      fake.userMessages.filter((message) => message.message.content === "Please continue.")
    ).toHaveLength(0)
    const endedPayload = events
      .map((event) => event.payload as Record<string, unknown>)
      .find((payload) => payload.turnState === "ended")
    expect(endedPayload?.stopDetail).toBe(
      "You've reached your 5-hour Claude usage limit. Try again after it resets."
    )
    expect(endedPayload?.retryable).toBeUndefined()
  })

  it("still retries a temporary Claude rate limit", async () => {
    vi.useFakeTimers()
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

    const promptPromise = run(created.handle.prompt("do work"))
    await settle()
    fake.push(assistantErrorMessage("rate_limit"))
    fake.push(resultMessage("error_during_execution"))
    await settle()

    expect(events.at(-1)).toMatchObject({
      kind: "session.updated",
      payload: {
        retrying: {
          attempt: 1,
          message: "Claude is temporarily rate limited, restarting response",
          of: 3
        }
      }
    })
    await vi.advanceTimersByTimeAsync(1000)
    await settle()
    expect(
      fake.userMessages.filter((message) => message.message.content === "Please continue.")
    ).toHaveLength(1)

    fake.push(resultMessage("success"))
    await promptPromise
  })
})

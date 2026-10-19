import type { SDKControlGetContextUsageResponse } from "@anthropic-ai/claude-agent-sdk"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { afterEach, describe, expect, it, vi } from "vitest"

import { claudeSessionContextFrom } from "./session-context.js"
import {
  assistantErrorMessage,
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  payloadOf,
  rateLimitEvent,
  resultMessage,
  resultWith,
  run,
  sdkMessage
} from "./test-support.js"
import { CLAUDE_OAUTH_USAGE_URL, claudeUsageLimitsFrom } from "./usage.js"

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
        five_hour: { utilization: 31, resets_at: "2026-07-15T20:00:00.123456+00:00" },
        seven_day: { utilization: 64, resets_at: "2026-07-20T00:00:00Z" },
        seven_day_opus: null,
        seven_day_sonnet: null,
        extra_usage: { is_enabled: false, monthly_limit: null, used_credits: null, utilization: 0 }
      },
      behaviors: null
    })

    expect(limits).toMatchObject({
      state: "available",
      plan: "max",
      windows: [
        {
          id: "five-hour",
          label: "5-hour limit",
          resetsAt: "2026-07-15T20:00:00.123Z",
          usedPercent: 31
        },
        {
          id: "seven-day",
          label: "Weekly limit",
          resetsAt: "2026-07-20T00:00:00.000Z",
          usedPercent: 64
        }
      ]
    })
  })
})

describe("Claude account usage for token-only accounts", () => {
  const sharedAccount = {
    id: "shared-account",
    profileKind: "managed" as const,
    env: { CLAUDE_CODE_OAUTH_TOKEN: "shared-token" }
  }

  it("reads plan windows straight from the usage endpoint without starting Claude", async () => {
    const fake = new FakeQuery()
    const request = vi.fn(
      async (_url: string | URL | Request, _init?: RequestInit) =>
        new Response(
          JSON.stringify({
            five_hour: { utilization: 4, resets_at: "2026-10-19T01:50:00.167448+00:00" },
            seven_day: { utilization: 12, resets_at: "2026-10-25T02:00:00+00:00" },
            extra_usage: { is_enabled: false, utilization: 0 },
            limits: [
              { kind: "session", percent: 4, scope: null },
              {
                kind: "weekly_scoped",
                percent: 30,
                resets_at: "2026-10-25T02:00:00+00:00",
                scope: { model: { display_name: "Fable" } }
              }
            ]
          })
        )
    )
    const provider = makeProvider(fake, undefined, undefined, { fetch: request })

    const limits = await run(provider.readUsageLimits!(definition, "/tmp", sharedAccount))

    expect(limits).toMatchObject({
      state: "available",
      windows: [
        { id: "five-hour", usedPercent: 4, resetsAt: "2026-10-19T01:50:00.167Z" },
        { id: "seven-day", usedPercent: 12 },
        { id: "model-0", label: "Weekly Fable", usedPercent: 30 }
      ]
    })
    expect(request).toHaveBeenCalledOnce()
    const [url, init] = request.mock.calls[0]!
    expect(url).toBe(CLAUDE_OAUTH_USAGE_URL)
    expect(new Headers(init?.headers).get("authorization")).toBe("Bearer shared-token")
    expect(fake.promptInput).toBeUndefined()
  })

  it("reports the endpoint's refusal as unavailable", async () => {
    const provider = makeProvider(new FakeQuery(), undefined, undefined, {
      fetch: async () => new Response("{}", { status: 429 })
    })

    expect(await run(provider.readUsageLimits!(definition, "/tmp", sharedAccount))).toMatchObject({
      detail: "Claude usage request failed with HTTP 429",
      state: "unavailable",
      windows: []
    })
  })
})

const contextUsage = (
  overrides: Partial<SDKControlGetContextUsageResponse>
): SDKControlGetContextUsageResponse => ({
  agents: [],
  apiUsage: null,
  categories: [],
  gridRows: [],
  isAutoCompactEnabled: true,
  maxTokens: 1_000_000,
  mcpTools: [],
  memoryFiles: [],
  model: "claude-opus-5-5",
  percentage: 0,
  rawMaxTokens: 1_000_000,
  totalTokens: 0,
  ...overrides
})

describe("ClaudeProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("reads the live context breakdown by category", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const createPromise = run(provider.createSession(definition, "/tmp", async () => undefined))
    fake.push(initMessage("sdk-session-1", "claude-sonnet-4-6"))
    const created = await createPromise
    await expect(run(created.handle.readContext!)).rejects.toThrow(
      "Claude context usage is unavailable"
    )

    fake.contextUsage = contextUsage({
      categories: [
        { color: "permission", name: "Messages", tokens: 219_800 },
        { color: "inactive", isDeferred: true, name: "MCP tools (deferred)", tokens: 247_700 }
      ],
      mcpTools: [
        { isLoaded: true, name: "mcp__linear__list_issues", serverName: "linear", tokens: 900 },
        { name: "mcp__notion__search", serverName: "notion", tokens: 600 }
      ],
      totalTokens: 268_200
    })

    await expect(run(created.handle.readContext!)).resolves.toEqual({
      categories: [
        { color: "permission", name: "Messages", tokens: 219_800 },
        { color: "inactive", isDeferred: true, name: "MCP tools (deferred)", tokens: 247_700 }
      ],
      maxTokens: 1_000_000,
      mcpTools: [
        { isLoaded: true, name: "mcp__linear__list_issues", serverName: "linear", tokens: 900 },
        { name: "mcp__notion__search", serverName: "notion", tokens: 600 }
      ],
      model: "claude-opus-5-5",
      totalTokens: 268_200
    })
  })

  it("leaves out an empty context model", () => {
    const context = claudeSessionContextFrom(contextUsage({ maxTokens: 200_000, model: "" }))
    expect(context).toEqual({ categories: [], maxTokens: 200_000, mcpTools: [], totalTokens: 0 })
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
    fake.push(initMessage("sdk-session-1", "claude-sonnet-4-6"))
    const created = await createPromise
    const prompt = run(created.handle.prompt("hello"))
    await fake.nextPrompt()

    fake.push(
      sdkMessage({
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
      })
    )
    fake.push(
      sdkMessage({
        ...resultMessage(),
        modelUsage: {
          "claude-sonnet-4-6": { contextWindow: 200_000 }
        },
        total_cost_usd: 0.25,
        usage: { input_tokens: 1_300, output_tokens: 100 }
      })
    )

    await prompt
    await fake.drain()

    const update = events.find(
      (event) =>
        event.kind === "session.updated" && payloadOf(event).sessionUpdate === "usage_update"
    )
    expect(payloadOf(update)).toMatchObject({
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
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("do work"))
    await fake.nextPrompt()

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
        (event) => event.kind === "session.updated" && payloadOf(event).retrying !== undefined
      )
    ).toHaveLength(0)
    const endedPayload = events.map(payloadOf).find((payload) => payload.turnState === "ended")
    expect(endedPayload?.stopDetail).toBe(limitMessage)
    expect(endedPayload?.stopKind).toBe("usageLimit")
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
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("do work"))
    await fake.nextPrompt()
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
    const endedPayload = events.map(payloadOf).find((payload) => payload.turnState === "ended")
    expect(endedPayload?.stopDetail).toBe(
      "You've reached your 5-hour Claude usage limit. Try again after it resets."
    )
    expect(endedPayload?.stopKind).toBe("usageLimit")
    expect(endedPayload?.retryable).toBeUndefined()
  })

  it("reports live plan usage from Claude rate limit events", async () => {
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

    const promptPromise = run(created.handle.prompt("do work"))
    await fake.nextPrompt()
    fake.push(rateLimitEvent({ rateLimitType: "five_hour", status: "allowed" }))
    fake.push(
      rateLimitEvent({
        rateLimitType: "seven_day",
        resetsAt: 1_792_900_800,
        status: "allowed_warning",
        utilization: 0.42
      })
    )
    fake.push(resultMessage())
    await promptPromise

    const observed = events
      .map(payloadOf)
      .filter((payload) => payload.sessionUpdate === "usage_limits_update")
    expect(observed).toEqual([
      expect.objectContaining({
        partial: true,
        limits: expect.objectContaining({
          state: "available",
          windows: [
            {
              durationMinutes: 10_080,
              id: "seven-day",
              label: "Weekly limit",
              resetsAt: "2026-10-25T04:00:00.000Z",
              usedPercent: 42
            }
          ]
        })
      })
    ])
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
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("do work"))
    await fake.nextPrompt()
    fake.push(assistantErrorMessage("rate_limit"))
    fake.push(resultMessage("error_during_execution"))
    await fake.drain()

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
    await fake.drain()
    expect(
      fake.userMessages.filter((message) => message.message.content === "Please continue.")
    ).toHaveLength(1)

    fake.push(resultMessage("success"))
    await promptPromise
  })
})

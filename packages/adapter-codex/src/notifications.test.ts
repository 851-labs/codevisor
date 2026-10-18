import { describe, expect, it } from "vitest"

import { payloadField, payloadOf, run, setup, UNIFIED_DIFF } from "./test-support.js"

describe("CodexProvider", () => {
  it("keeps last-turn and cumulative usage distinct and omits nonfinite counters", async () => {
    const { client, created, events } = await setup()
    try {
      client.emit("thread/tokenUsage/updated", {
        threadId: "thread-new",
        tokenUsage: {
          last: { totalTokens: 7 },
          modelContextWindow: 256,
          total: {
            inputTokens: 10,
            cachedInputTokens: 2,
            outputTokens: 3,
            reasoningOutputTokens: 1,
            totalTokens: 13
          }
        }
      })
      client.emit("thread/tokenUsage/updated", {
        threadId: "thread-new",
        tokenUsage: {
          last: { totalTokens: Number.NaN },
          modelContextWindow: Number.POSITIVE_INFINITY,
          total: {
            inputTokens: 0,
            cachedInputTokens: -2,
            outputTokens: "3",
            reasoningOutputTokens: null,
            totalTokens: 9
          }
        }
      })
      expect(events).toEqual([
        {
          kind: "session.updated",
          payload: {
            sessionUpdate: "usage_update",
            used: 7,
            size: 256,
            inputTokens: 10,
            cachedInputTokens: 2,
            outputTokens: 3,
            reasoningOutputTokens: 1,
            totalTokens: 13
          },
          subjectId: "thread-new"
        },
        {
          kind: "session.updated",
          payload: {
            sessionUpdate: "usage_update",
            inputTokens: 0,
            cachedInputTokens: -2,
            totalTokens: 9
          },
          subjectId: "thread-new"
        }
      ])
    } finally {
      await run(created!.handle.close)
    }
  })

  it("reports live Codex plan usage and ignores other limit buckets", async () => {
    const { client, created, events } = await setup()
    try {
      client.emit("account/rateLimits/updated", {
        rateLimits: {
          limitId: "codex",
          primary: { resetsAt: 1_792_900_800, usedPercent: 18, windowDurationMins: 10_080 }
        }
      })
      client.emit("account/rateLimits/updated", {
        rateLimits: {
          limitId: "codex_other",
          primary: { usedPercent: 90, windowDurationMins: 300 }
        }
      })
      expect(
        events.map(payloadOf).filter((payload) => payload.sessionUpdate === "usage_limits_update")
      ).toEqual([
        expect.objectContaining({
          partial: true,
          limits: expect.objectContaining({
            windows: [
              {
                durationMinutes: 10_080,
                id: "primary",
                label: "Weekly limit",
                resetsAt: "2026-10-25T04:00:00.000Z",
                usedPercent: 18
              }
            ]
          })
        })
      ])
    } finally {
      await run(created!.handle.close)
    }
  })

  it("normalizes Codex context-compaction item lifecycle", async () => {
    const { client, events } = await setup()
    client.emit("item/started", {
      item: { id: "compact-1", type: "contextCompaction" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: { id: "compact-1", type: "contextCompaction" },
      threadId: "thread-new",
      turnId: "turn-1"
    })

    expect(events.map((event) => event.payload)).toEqual(
      expect.arrayContaining([
        { compactionId: "compact-1", sessionUpdate: "context_compaction", status: "started" },
        { compactionId: "compact-1", sessionUpdate: "context_compaction", status: "completed" }
      ])
    )
  })

  it("emits the app-server title after a completed turn", async () => {
    const { client, created, events } = await setup()
    client.threadName = "Harness title"
    client.threadPreview = "First prompt"
    const turnRequested = client.nextRequest("turn/start")
    const prompt = run(created!.handle.prompt("hello"))
    await turnRequested
    client.emit("turn/started", {
      threadId: "thread-new",
      turn: { id: "turn-title", status: "inProgress" }
    })
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "turn-title", status: "completed" }
    })
    await prompt

    expect(events.map((event) => event.payload)).toContainEqual({
      sessionUpdate: "session_info_update",
      title: "Harness title"
    })
  })

  it("surfaces harness retries and marks an exhausted overload retryable", async () => {
    const { client, created, events } = await setup()
    const turnRequested = client.nextRequest("turn/start")
    const prompt = run(created!.handle.prompt("try this"))
    await turnRequested
    client.emit("turn/started", {
      threadId: "thread-new",
      turn: { id: "turn-overloaded", status: "inProgress" }
    })
    client.emit("error", {
      error: {
        codexErrorInfo: "serverOverloaded",
        message: "Server is busy. Reconnecting... 2/5"
      },
      threadId: "thread-new",
      turnId: "turn-overloaded",
      willRetry: true
    })

    expect(events.at(-1)?.payload).toMatchObject({
      retrying: {
        attempt: 2,
        message: "Codex is overloaded, retrying",
        of: 5
      },
      turnId: "turn-overloaded"
    })

    client.emit("error", {
      error: { codexErrorInfo: "serverOverloaded", message: "The server is overloaded." },
      threadId: "thread-new",
      turnId: "turn-overloaded",
      willRetry: false
    })
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: {
        id: "turn-overloaded",
        status: "failed"
      }
    })
    await prompt

    expect(events.some((event) => event.kind === "session.error")).toBe(false)
    expect(events.at(-1)?.payload).toMatchObject({
      retryable: true,
      stopDetail: "The server is overloaded.",
      turnState: "ended"
    })
  })

  it("preserves Codex's usage-limit guidance instead of presenting it as a retry", async () => {
    const { client, created, events } = await setup()
    const turnRequested = client.nextRequest("turn/start")
    const prompt = run(created!.handle.prompt("try this"))
    await turnRequested
    client.emit("turn/started", {
      threadId: "thread-new",
      turn: { id: "turn-usage-limit", status: "inProgress" }
    })
    const usageMessage =
      "You've hit your usage limit. Visit Codex settings to purchase more credits or try again tomorrow."
    client.emit("error", {
      error: {
        codexErrorInfo: "usageLimitExceeded",
        message: usageMessage
      },
      threadId: "thread-new",
      turnId: "turn-usage-limit",
      willRetry: false
    })
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: {
        id: "turn-usage-limit",
        status: "failed"
      }
    })
    await prompt

    expect(
      events.some(
        (event) => event.kind === "session.updated" && payloadField(event, "retrying") !== undefined
      )
    ).toBe(false)
    expect(events.at(-1)?.payload).toMatchObject({
      stopDetail: usageMessage,
      stopKind: "usageLimit",
      turnState: "ended"
    })
    expect(payloadOf(events.at(-1)).retryable).toBeUndefined()
  })

  it("ends a turn Codex rejected as unauthorized as needing sign-in", async () => {
    const { client, created, events } = await setup()
    const turnRequested = client.nextRequest("turn/start")
    const prompt = run(created!.handle.prompt("try this"))
    await turnRequested
    client.emit("turn/started", {
      threadId: "thread-new",
      turn: { id: "turn-401", status: "inProgress" }
    })
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: {
        id: "turn-401",
        status: "failed",
        error: {
          message: "unexpected status 401 Unauthorized: Missing bearer or basic authentication",
          codexErrorInfo: { httpConnectionFailed: { httpStatusCode: 401 } }
        }
      }
    })
    expect(await prompt).toMatchObject({ stopReason: "end_turn" })
    expect(events.at(-1)?.payload).toMatchObject({
      stopDetail: "Codex isn't signed in. Sign in to continue.",
      stopKind: "authRequired",
      turnState: "ended"
    })
  })

  it("stops Codex's own retries once a request is rejected as unauthorized", async () => {
    const { client, created, events } = await setup()
    const turnRequested = client.nextRequest("turn/start")
    const prompt = run(created!.handle.prompt("try this"))
    await turnRequested
    client.emit("turn/started", {
      threadId: "thread-new",
      turn: { id: "turn-retrying-401", status: "inProgress" }
    })
    const interrupted = client.nextRequest("turn/interrupt")
    const retry = (attempt: number) =>
      client.emit("error", {
        error: {
          message: `Reconnecting... ${attempt}/5`,
          codexErrorInfo: { responseStreamDisconnected: { httpStatusCode: 401 } }
        },
        threadId: "thread-new",
        turnId: "turn-retrying-401",
        willRetry: true
      })
    retry(1)
    retry(2)
    await interrupted
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "turn-retrying-401", status: "interrupted" }
    })
    expect(await prompt).toMatchObject({ stopReason: "end_turn" })
    expect(client.requests.filter((request) => request.method === "turn/interrupt")).toHaveLength(1)
    expect(events.some((event) => payloadField(event, "retrying") !== undefined)).toBe(false)
    expect(events.at(-1)?.payload).toMatchObject({
      stopKind: "authRequired",
      stopReason: "end_turn",
      turnState: "ended"
    })
  })

  it("asks Codex whether a ChatGPT sign-in is gone when a turn fails without a reason", async () => {
    const { client, created, events } = await setup()
    client.account = { account: null, requiresOpenaiAuth: true }
    const turnRequested = client.nextRequest("turn/start")
    const prompt = run(created!.handle.prompt("try this"))
    await turnRequested
    client.emit("turn/started", {
      threadId: "thread-new",
      turn: { id: "turn-chatgpt", status: "inProgress" }
    })
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: {
        id: "turn-chatgpt",
        status: "failed",
        error: {
          message: "workspace routing discovery unauthorized (401)",
          codexErrorInfo: "other"
        }
      }
    })
    await prompt
    expect(client.requests).toContainEqual({
      method: "account/read",
      params: { refreshToken: false }
    })
    expect(events.at(-1)?.payload).toMatchObject({ stopKind: "authRequired", turnState: "ended" })
  })

  it("keeps an unexplained failure as-is while the ChatGPT account is still signed in", async () => {
    const { client, created, events } = await setup()
    client.account = { account: { type: "chatgpt" }, requiresOpenaiAuth: true }
    const turnRequested = client.nextRequest("turn/start")
    const prompt = run(created!.handle.prompt("try this"))
    await turnRequested
    client.emit("turn/started", {
      threadId: "thread-new",
      turn: { id: "turn-other", status: "failed" }
    })
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: {
        id: "turn-other",
        status: "failed",
        error: { message: "boom", codexErrorInfo: "other" }
      }
    })
    await prompt
    expect(events.at(-1)?.payload).toMatchObject({ stopDetail: "boom", turnState: "ended" })
    expect(payloadOf(events.at(-1)).stopKind).toBeUndefined()
  })

  it("labels a retryable HTTP 429 as temporary request throttling", async () => {
    const { client, created, events } = await setup()
    const turnRequested = client.nextRequest("turn/start")
    const prompt = run(created!.handle.prompt("try this"))
    await turnRequested
    client.emit("turn/started", {
      threadId: "thread-new",
      turn: { id: "turn-throttled", status: "inProgress" }
    })
    client.emit("error", {
      error: {
        codexErrorInfo: {
          responseStreamConnectionFailed: { httpStatusCode: 429 }
        },
        message: "Request throttled. Retrying... 1/4"
      },
      threadId: "thread-new",
      turnId: "turn-throttled",
      willRetry: true
    })

    expect(events.at(-1)?.payload).toMatchObject({
      retrying: {
        attempt: 1,
        message: "Codex is temporarily rate limited, retrying",
        of: 4
      },
      turnId: "turn-throttled"
    })

    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "turn-throttled", status: "completed" }
    })
    await prompt
  })

  it("opens the tool call from the first streamed patch update (arrives before item/started)", async () => {
    const { client, events } = await setup()
    client.emit("item/fileChange/patchUpdated", {
      changes: [{ diff: UNIFIED_DIFF, kind: { type: "update" }, path: "release.yml" }],
      itemId: "item-early",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    const opened = payloadOf(events.at(-1))
    expect(opened).toMatchObject({
      sessionUpdate: "tool_call",
      toolCallId: "item-early",
      kind: "edit",
      status: "in_progress",
      title: "Editing release.yml",
      diffStats: [{ added: 2, path: "release.yml", removed: 1 }]
    })

    client.emit("item/fileChange/patchUpdated", {
      changes: [{ diff: UNIFIED_DIFF + "\n+more", kind: { type: "update" }, path: "release.yml" }],
      itemId: "item-early",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    const streamed = payloadOf(events.at(-1))
    expect(streamed).toMatchObject({
      sessionUpdate: "tool_call_update",
      toolCallId: "item-early",
      status: "in_progress",
      diffStats: [{ added: 3, path: "release.yml", removed: 1 }]
    })

    client.emit("item/started", {
      item: {
        changes: [{ diff: UNIFIED_DIFF, kind: { type: "update" }, path: "release.yml" }],
        id: "item-early",
        status: "inProgress",
        type: "fileChange"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(payloadOf(events.at(-1)).sessionUpdate).toBe("tool_call")
  })

  it("drives the thinking state from reasoning item lifecycles", async () => {
    const { client, events } = await setup()
    client.emit("item/started", {
      item: { id: "rs_1", type: "reasoning" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(events.at(-1)?.payload).toMatchObject({ sessionUpdate: "agent_thought_chunk" })
    const count = events.length
    client.emit("item/completed", {
      item: { id: "rs_1", summary: [], type: "reasoning" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(events.length).toBe(count)
  })

  it("labels goal auto-continuation turns as agent-initiated", async () => {
    const { client, events } = await setup({ resume: "thread-resumed" })
    client.emit("thread/goal/updated", {
      goal: {
        createdAt: 1_700_000_000,
        objective: "keep going",
        status: "active",
        threadId: "thread-resumed",
        timeUsedSeconds: 0,
        tokenBudget: null,
        tokensUsed: 0,
        updatedAt: 1_700_000_000
      },
      threadId: "thread-resumed",
      turnId: null
    })
    client.emit("turn/started", { threadId: "thread-resumed", turn: { id: "turn-goal" } })
    const started = events.at(-1)
    expect(started?.payload).toMatchObject({
      initiatedBy: "agent",
      turnId: "turn-goal",
      turnState: "started"
    })
  })
})

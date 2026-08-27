import { describe, expect, it } from "vitest"
import { run, setup, UNIFIED_DIFF } from "./test-support.js"

describe("CodexProvider", () => {
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
    const prompt = run(created!.handle.prompt("hello"))
    await Promise.resolve()
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
    const prompt = run(created!.handle.prompt("try this"))
    await Promise.resolve()
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
    const prompt = run(created!.handle.prompt("try this"))
    await Promise.resolve()
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
        (event) =>
          event.kind === "session.updated" &&
          (event.payload as Record<string, unknown>).retrying !== undefined
      )
    ).toBe(false)
    expect(events.at(-1)?.payload).toMatchObject({
      stopDetail: usageMessage,
      stopKind: "usageLimit",
      turnState: "ended"
    })
    expect((events.at(-1)?.payload as Record<string, unknown>).retryable).toBeUndefined()
  })

  it("labels a retryable HTTP 429 as temporary request throttling", async () => {
    const { client, created, events } = await setup()
    const prompt = run(created!.handle.prompt("try this"))
    await Promise.resolve()
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
    const opened = events.at(-1)?.payload as Record<string, unknown>
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
    const streamed = events.at(-1)?.payload as Record<string, unknown>
    expect(streamed).toMatchObject({
      sessionUpdate: "tool_call_update",
      toolCallId: "item-early",
      status: "in_progress",
      diffStats: [{ added: 3, path: "release.yml", removed: 1 }]
    })

    // item/started for the same id merges rather than duplicating.
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
    expect((events.at(-1)!.payload as Record<string, unknown>).sessionUpdate).toBe("tool_call")
  })

  it("drives the thinking state from reasoning item lifecycles", async () => {
    const { client, events } = await setup()
    client.emit("item/started", {
      item: { id: "rs_1", type: "reasoning" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(events.at(-1)?.payload).toMatchObject({ sessionUpdate: "agent_thought_chunk" })
    // Completion emits nothing extra; the next message/tool clears the state
    // client-side.
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
    // Resume flow: codex replays a goal snapshot then may start a turn itself.
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

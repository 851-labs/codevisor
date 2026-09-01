import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
  it("uses monotonic per-session revisions independent of the global event log", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/session-revisions" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    expect(await run(db.latestEventCursor)).toBe(0)

    const first = await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
    await run(db.appendEvent("project.updated", project.id, { title: "unrelated" }))
    const second = await run(
      db.appendEvent("session.output", session.id, {
        role: "assistant",
        text: "hello"
      })
    )

    expect(first.subjectRevision).toBe(1)
    expect(first.globalEventId).toBeUndefined()
    expect(second.subjectRevision).toBe(2)
    expect(second.id).toBe(2)
    expect(second.globalEventId).toBeUndefined()
    expect((await run(db.listSubjectEvents(session.id))).map((event) => event.id)).toEqual([1, 2])
    const assistantItem = (await run(db.getTranscriptPage(session.id, undefined, 8))).items.find(
      (item) => item.role === "assistant"
    )
    expect(assistantItem).toBeDefined()
    expect(first.payload).toMatchObject({ chatItemId: assistantItem?.id })
    expect(second.payload).toMatchObject({ chatItemId: assistantItem?.id })
    expect((await run(db.listSubjectEvents(session.id)))[0]?.payload).toMatchObject({
      chatItemId: assistantItem?.id
    })
    expect((await run(db.listEvents(0))).map((event) => event.kind)).toEqual(["project.updated"])
    expect(await run(db.latestEventCursor)).toBe(1)
    expect((await run(db.getTranscriptPage(session.id, undefined, 8))).eventCursor).toBe(2)
    await Effect.runPromise(db.close)
  })

  it("persists detailed session usage into summaries and transcript snapshots", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/session-usage" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "claude-code" }))

    await run(
      db.appendEvent("session.updated", session.id, {
        sessionUpdate: "usage_update",
        inputTokens: 1_200,
        cachedInputTokens: 800,
        outputTokens: 300,
        reasoningOutputTokens: 100,
        totalTokens: 2_300,
        cost: { amount: 0.42, currency: "USD", kind: "reported" }
      })
    )

    // Malformed optional fields must not erase the last valid projection.
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "usage_update",
        cost: { amount: "unknown", currency: 42, kind: "unknown" }
      })
    )

    const usage = {
      inputTokens: 1_200,
      cachedInputTokens: 800,
      outputTokens: 300,
      reasoningOutputTokens: 100,
      totalTokens: 2_300,
      costAmount: 0.42,
      costCurrency: "USD",
      costKind: "reported"
    }
    expect((await run(db.getSessionSummary(session.id))).usage).toMatchObject(usage)
    expect((await run(db.getTranscriptPage(session.id, undefined, 8))).usage).toMatchObject(usage)
    await Effect.runPromise(db.close)
  })

  it("coalesces streamed chunks of the same message into one conversation row", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    expect(await run(db.migrate)).toEqual([])
    const project = await run(db.createProject({ folderPath: "/tmp/coalesce" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    // Token-sized chunks sharing a messageId extend the same row — one row
    // per message, not one per token (a 3000-word answer used to persist as
    // thousands of rows).
    await run(db.appendConversationItem(session.id, "user", "user-1", "tell me", false))
    await run(db.appendConversationItem(session.id, "assistant", "msg-1", "Hel", true))
    await run(db.appendConversationItem(session.id, "assistant", "msg-1", "lo ", true))
    await run(db.appendConversationItem(session.id, "assistant", "msg-1", "world", false))
    // A new messageId starts a new row; a chunk without one never coalesces.
    await run(db.appendConversationItem(session.id, "assistant", "msg-2", "Next", false))
    await run(db.appendConversationItem(session.id, "assistant", undefined, "loose", false))
    await run(db.appendConversationItem(session.id, "assistant", undefined, "loose2", false))
    // Role changes break a run even with a matching id shape.
    await run(db.appendConversationItem(session.id, "user", "msg-2", "reply", false))

    const detail = await run(db.getSessionDetail(session.id))
    expect(
      detail.conversation.map((item) => [item.role, item.messageId, item.text, item.isGenerating])
    ).toEqual([
      ["user", "user-1", "tell me", false],
      ["assistant", "msg-1", "Hello world", false],
      ["assistant", "msg-2", "Next", false],
      ["assistant", undefined, "loose", false],
      ["assistant", undefined, "loose2", false],
      ["user", "msg-2", "reply", false]
    ])
  })

  it("projects bounded transcript pages and item-scoped details as events arrive", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/transcript-pages" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    await run(db.appendEvent("session.output", session.id, { role: "user", text: "Explain it" }))
    await run(
      db.appendEvent("session.updated", session.id, { turnId: "turn-1", turnState: "started" })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        content: { type: "text", text: "Hello " },
        messageId: "answer-1",
        sessionUpdate: "agent_message_chunk"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        content: { type: "text", text: "world" },
        messageId: "answer-1",
        sessionUpdate: "agent_message_chunk"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "tool_call",
        toolCallId: "tool-1",
        title: "Read a file"
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "turn-1",
        turnState: "ended",
        stopReason: "end_turn"
      })
    )

    const newest = await run(db.getTranscriptPage(session.id, undefined, 1))
    expect(newest).toMatchObject({ hasMore: true, nextBefore: "1", eventCursor: 6 })
    expect(newest.items).toHaveLength(1)
    expect(newest.items[0]).toMatchObject({
      sequence: 1,
      role: "assistant",
      text: "Hello world",
      isGenerating: false,
      hasDetails: true,
      turnId: "turn-1",
      stopReason: "end_turn"
    })

    const older = await run(db.getTranscriptPage(session.id, 1, 1))
    expect(older).toMatchObject({ hasMore: false, eventCursor: 6 })
    expect(older.nextBefore).toBeUndefined()
    expect(older.items).toMatchObject([{ sequence: 0, role: "user", text: "Explain it" }])

    const details = await run(db.getTranscriptItemDetails(session.id, newest.items[0]!.id))
    expect(details?.itemId).toBe(newest.items[0]!.id)
    expect(details?.events.map((event) => event.id)).toEqual([2, 3, 4, 5, 6])
    const snapshotDetails = await run(
      db.getTranscriptItemDetails(session.id, newest.items[0]!.id, 4)
    )
    expect(snapshotDetails?.events.map((event) => event.id)).toEqual([2, 3, 4])
    expect(await run(db.getTranscriptItemDetails(session.id, "missing"))).toBeUndefined()
  })

  it("reuses the original user transcript row when a response retry echoes its message id", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/retry-transcript" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    await run(
      db.appendEvent("session.output", session.id, {
        role: "user",
        messageId: "original-message",
        text: "Fix the issue"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        role: "user",
        messageId: "original-message",
        text: "Continue from the failed attempt without repeating completed work."
      })
    )

    const transcript = await run(db.getTranscriptPage(session.id, undefined, 32))
    expect(transcript.items.filter((item) => item.role === "user")).toMatchObject([
      { text: "Fix the issue" }
    ])
    await run(db.close)
  })

  it("projects alternate event shapes, plans, tools, and failed turns", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/event-shapes" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    await run(db.appendEvent("session.output", session.id, "ignored non-object payload"))
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "user_message_chunk",
        content: { type: "text", text: "chunked question" },
        messageId: "question-1"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "user_message_chunk",
        text: "without id"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        role: "system",
        text: "system context",
        attachments: []
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "turn-routed",
        turnState: "started"
      })
    )
    const streamingPage = await run(db.getTranscriptPage(session.id, undefined, 32))
    expect(streamingPage.items.at(-1)).toMatchObject({
      isGenerating: true,
      text: ""
    })
    expect(streamingPage.items.at(-1)?.planDocument).toBeUndefined()
    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "turn-routed",
        turnState: "started"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        role: "assistant",
        text: "direct ",
        messageId: "answer-1"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "thinking" },
        messageId: "commentary-1",
        phase: "commentary"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "answer" },
        messageId: "answer-2",
        phase: "final"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        text: "anonymous answer"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "image" }
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "" },
        messageId: "empty"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "plan_document",
        markdown: "- [ ] ship"
      })
    )
    expect(
      (await run(db.getTranscriptPage(session.id, undefined, 32))).items.at(-1)?.planDocument
    ).toBe("- [ ] ship")
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "tool_call",
        toolCallId: "tool-1",
        text: "tool detail"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "tool_call_update",
        parentToolCallId: "tool-1",
        toolCallId: "tool-child"
      })
    )
    await run(
      db.appendEvent("session.error", session.id, {
        message: "provider failed",
        retryable: true,
        stopReason: "error",
        turnId: "unknown-turn"
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "turn-empty",
        turnState: "started"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        text: "commentary only",
        phase: "commentary"
      })
    )
    await run(db.appendEvent("session.updated", session.id, { turnState: "ended" }))
    await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
    await run(
      db.appendEvent("session.updated", session.id, {
        stopReason: "manual",
        stopDetail: "manual detail",
        stopKind: "usageLimit"
      })
    )
    // A terminal event with no active item is a harmless no-op.
    await run(db.appendEvent("session.updated", session.id, { turnState: "ended" }))
    await run(
      db.appendEvent("session.created", session.id, {
        id: session.id,
        projectId: project.id
      })
    )
    await run(
      db.appendEvent("session.archived", session.id, {
        id: session.id,
        projectId: project.id
      })
    )
    await run(
      db.appendEvent("session.deleted", session.id, {
        id: session.id,
        projectId: project.id
      })
    )
    await run(db.appendEvent("session.updated", project.id, null))
    await run(db.appendEvent("session.updated", project.id, { id: "metadata-without-project" }))
    await run(db.appendEvent("session.updated", session.id, { id: "metadata-without-project" }))
    await run(db.appendEvent("session.output", "missing-subject", { text: "orphan" }))

    const page = await run(db.getTranscriptPage(session.id, undefined, 32))
    expect(page.items.map((item) => item.role)).toEqual([
      "user",
      "user",
      "assistant",
      "assistant",
      "assistant"
    ])
    expect(page.items[0]?.text).toBe("chunked question")
    expect(page.items[1]?.text).toBe("without id")
    expect(page.items[2]).toMatchObject({
      hasDetails: true,
      isGenerating: false,
      planDocument: "- [ ] ship",
      retryable: true,
      text: "anonymous answer",
      stopDetail: "provider failed",
      stopReason: "error"
    })
    expect(page.items[3]?.text).toBe("")
    expect(page.items[3]?.stopReason).toBeUndefined()
    expect(page.items[2]?.stopKind).toBeUndefined()
    expect(page.items[4]).toMatchObject({
      text: "",
      stopKind: "usageLimit",
      stopReason: "manual"
    })
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({ id: session.id })
    expect((await run(db.listSubjectEvents(session.id))).length).toBeGreaterThan(20)
    expect((await run(db.listSubjectEvents(project.id))).length).toBeGreaterThan(0)
    expect((await run(db.listSubjectEvents("missing-subject"))).length).toBe(1)
    await Effect.runPromise(db.close)
  })

  it("does not project ACP startup metadata as an assistant turn", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/acp-startup-metadata" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "opencode" }))

    await run(
      db.appendEvent("session.output", session.id, {
        availableCommands: [{ description: "Start a new session", name: "new" }],
        sessionUpdate: "available_commands_update"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        currentModeId: "build",
        sessionUpdate: "current_mode_update"
      })
    )

    expect((await run(db.getTranscriptPage(session.id, undefined, 32))).items).toEqual([])

    await run(db.appendEvent("session.output", session.id, { role: "user", text: "hello" }))
    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "first-turn",
        turnState: "started"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        content: { type: "text", text: "Hello! How can I help?" },
        sessionUpdate: "agent_message_chunk"
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "first-turn",
        turnState: "ended"
      })
    )

    expect((await run(db.getTranscriptPage(session.id, undefined, 32))).items).toMatchObject([
      { role: "user", text: "hello" },
      { role: "assistant", text: "Hello! How can I help?" }
    ])
    await run(db.close)
  })
})

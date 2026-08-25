import Database from "better-sqlite3"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
  it("snapshots the latest goal with the transcript cursor, including transient activity", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/goal-snapshot" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "grok-build" }))
    const goal = {
      objective: "ship goal mode",
      status: "active" as const,
      activity: "verifying" as const,
      tokenBudget: null,
      tokensUsed: 12_000,
      timeUsedSeconds: 42,
      createdAt: "2026-07-16T20:00:00.000Z",
      updatedAt: "2026-07-16T20:00:42.000Z"
    }

    await run(db.appendEvent("session.updated", session.id, { goal }))
    expect((await run(db.getTranscriptPage(session.id, undefined, 8))).goal).toEqual(goal)
    expect((await run(db.getSessionDetail(session.id))).goal).toEqual(goal)

    await run(db.appendEvent("session.updated", session.id, { goalCleared: true }))
    expect((await run(db.getTranscriptPage(session.id, undefined, 8))).goal).toBeUndefined()
    expect((await run(db.getSessionDetail(session.id))).goal).toBeUndefined()
    await Effect.runPromise(db.close)
  })

  it("persists finalized assistant markdown and attachments across turn completion", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/assistant-attachments" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    const attachment = {
      fileId: "recording-1",
      name: "fixed.mov",
      mimeType: "video/quicktime",
      sizeBytes: 123,
      kind: "file" as const
    }

    await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        messageId: "answer-1",
        content: { type: "text", text: "[Recording](./fixed.mov)" }
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "assistant_message_finalized",
        messageId: "answer-1",
        markdown: "[Recording](https://attachments.codevisor.invalid/recording-1)",
        attachments: [attachment]
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        turnState: "ended",
        stopReason: "end_turn"
      })
    )

    const page = await run(db.getTranscriptPage(session.id, undefined, 8))
    expect(page.items).toMatchObject([
      {
        role: "assistant",
        text: "[Recording](https://attachments.codevisor.invalid/recording-1)",
        isGenerating: false,
        attachments: [attachment]
      }
    ])

    const fallbackSession = await run(
      db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    await run(db.appendEvent("session.updated", fallbackSession.id, { turnState: "started" }))
    await run(
      db.appendEvent("session.output", fallbackSession.id, {
        sessionUpdate: "agent_message_chunk",
        messageId: "answer-2",
        content: { type: "text", text: "Draft answer" }
      })
    )
    // Older or partially upgraded producers may omit optional finalization
    // fields. The projection still replaces the Markdown and treats
    // attachments as empty.
    await run(
      db.appendEvent("session.output", fallbackSession.id, {
        sessionUpdate: "assistant_message_finalized",
        markdown: "Final answer"
      })
    )
    await run(
      db.appendEvent("session.updated", fallbackSession.id, {
        turnState: "ended",
        stopReason: "end_turn"
      })
    )

    const fallbackPage = await run(db.getTranscriptPage(fallbackSession.id, undefined, 8))
    expect(fallbackPage.items).toMatchObject([
      {
        role: "assistant",
        text: "Final answer",
        isGenerating: false
      }
    ])
    expect(fallbackPage.items[0]?.attachments).toBeUndefined()
  })

  it("only marks assistant turns with renderable worked details", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/worked-details" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "empty-work",
        turnState: "started"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        content: { type: "text", text: "" },
        sessionUpdate: "agent_thought_chunk"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        content: { type: "text", text: "Answer without work" },
        sessionUpdate: "agent_message_chunk"
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "empty-work",
        turnState: "ended"
      })
    )

    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "visible-work",
        turnState: "started"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        content: { type: "text", text: "Inspecting files" },
        sessionUpdate: "agent_thought_chunk"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        content: { type: "text", text: "Answer after work" },
        sessionUpdate: "agent_message_chunk"
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        turnId: "visible-work",
        turnState: "ended"
      })
    )

    const page = await run(db.getTranscriptPage(session.id, undefined, 32))
    expect(page.items.filter((item) => item.role === "assistant")).toMatchObject([
      { text: "Answer without work", hasDetails: false },
      { text: "Answer after work", hasDetails: true }
    ])
  })

  it("exposes the streaming answer candidate's messageId until the item completes", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/streaming-message-id" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "claude-code" }))

    await run(
      db.appendEvent("session.updated", session.id, { turnId: "turn-1", turnState: "started" })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "first half" },
        messageId: "msg-1"
      })
    )
    // A mid-stream restore adopts the live span identity, so the streaming
    // snapshot must carry the provider message id of its answer candidate.
    expect((await run(db.getTranscriptPage(session.id, undefined, 8))).items.at(-1)).toMatchObject({
      isGenerating: true,
      text: "first half",
      messageId: "msg-1"
    })
    expect(
      (await run(db.getTranscriptPage(session.id, undefined, 8))).items.at(-1)?.phase
    ).toBeUndefined()

    // An empty chunk without provider identity cannot classify any existing
    // span and must leave the optimistic candidate untouched.
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "" }
      })
    )
    expect((await run(db.getTranscriptPage(session.id, undefined, 8))).items.at(-1)).toMatchObject({
      text: "first half",
      messageId: "msg-1"
    })

    // An answer candidate without provider identity has no id to hand back.
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        text: "anonymous tail"
      })
    )
    expect(
      (await run(db.getTranscriptPage(session.id, undefined, 8))).items.at(-1)?.messageId
    ).toBeUndefined()

    // Completed items render from accumulated parts with no live
    // continuation, so they never carry a messageId.
    await run(db.appendEvent("session.updated", session.id, { turnState: "ended" }))
    const completed = (await run(db.getTranscriptPage(session.id, undefined, 8))).items.at(-1)
    expect(completed?.isGenerating).toBe(false)
    expect(completed?.messageId).toBeUndefined()
    await run(db.close)
  })

  it("preserves asserted finality and applies zero-length commentary corrections", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/streaming-message-phase" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "claude-code" }))

    await run(
      db.appendEvent("session.updated", session.id, { turnId: "turn-1", turnState: "started" })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "I'll inspect that." },
        messageId: "msg-preamble"
      })
    )

    const optimistic = (await run(db.getTranscriptPage(session.id, undefined, 8))).items.at(-1)
    expect(optimistic).toMatchObject({
      isGenerating: true,
      text: "I'll inspect that.",
      messageId: "msg-preamble"
    })
    expect(optimistic?.phase).toBeUndefined()

    // Claude sends this when a tool starts after streamed prose. The empty
    // correction must demote the restored span just as the live reducer does.
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "" },
        messageId: "msg-preamble",
        phase: "commentary"
      })
    )
    const corrected = (await run(db.getTranscriptPage(session.id, undefined, 8))).items.at(-1)
    expect(corrected).toMatchObject({ isGenerating: true, text: "" })
    expect(corrected?.messageId).toBeUndefined()
    expect(corrected?.phase).toBeUndefined()

    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "The fix is complete." },
        messageId: "msg-final",
        phase: "final"
      })
    )
    expect((await run(db.getTranscriptPage(session.id, undefined, 8))).items.at(-1)).toMatchObject({
      isGenerating: true,
      text: "The fix is complete.",
      messageId: "msg-final",
      phase: "final"
    })
    await run(db.close)
  })

  it("fails stale streaming assistant items without touching the active item", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/stale-assistant-items" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    expect(await run(db.failStaleAssistantChatItems(session.id, "Server restarted"))).toBe(0)

    await run(
      db.appendEvent("session.updated", session.id, { turnId: "turn-stale", turnState: "started" })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        content: { type: "text", text: "durable answer" },
        messageId: "answer-stale",
        sessionUpdate: "agent_message_chunk"
      })
    )
    const stale = (await run(db.getTranscriptPage(session.id, undefined, 8))).items.at(-1)!

    expect(
      await run(db.failStaleAssistantChatItems(session.id, "Server restarted", stale.id))
    ).toBe(0)
    expect((await run(db.getTranscriptPage(session.id, undefined, 8))).items.at(-1)).toMatchObject({
      id: stale.id,
      isGenerating: true
    })

    expect(await run(db.failStaleAssistantChatItems(session.id, "Server restarted"))).toBe(1)
    expect((await run(db.getTranscriptPage(session.id, undefined, 8))).items.at(-1)).toMatchObject({
      id: stale.id,
      isGenerating: false,
      stopDetail: "Server restarted",
      stopReason: "interrupted",
      text: "durable answer"
    })

    // Clearing the failed projection pointer ensures later output opens a
    // fresh assistant item instead of reviving the interrupted one.
    await run(
      db.appendEvent("session.output", session.id, {
        content: { type: "text", text: "fresh answer" },
        messageId: "answer-fresh",
        sessionUpdate: "agent_message_chunk"
      })
    )
    const items = (await run(db.getTranscriptPage(session.id, undefined, 8))).items
    expect(items).toHaveLength(2)
    expect(items[1]).toMatchObject({ isGenerating: true, text: "fresh answer" })
    expect(items[1]?.id).not.toBe(stale.id)
    await run(db.close)
  })

  it("lists sessions with streaming items only once their event log is quiet", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/quiet-streaming" }))
    const streaming = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    const finished = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    await run(
      db.appendEvent("session.output", streaming.id, {
        content: { type: "text", text: "half-finished answer" },
        messageId: "quiet-msg",
        sessionUpdate: "agent_message_chunk"
      })
    )
    await run(
      db.appendEvent("session.output", finished.id, {
        content: { type: "text", text: "done answer" },
        messageId: "finished-msg",
        sessionUpdate: "agent_message_chunk"
      })
    )
    await run(db.appendEvent("session.updated", finished.id, { turnState: "ended" }))

    const beforeEvents = new Date(Date.now() - 60 * 60 * 1000).toISOString()
    const afterEvents = new Date(Date.now() + 60 * 60 * 1000).toISOString()

    // Events since the cutoff: the turn may still be live.
    expect(await run(db.listQuietStreamingSessions(beforeEvents))).toEqual([])
    // Quiet log + streaming row = stuck-turn candidate; sessions whose items
    // all completed never qualify no matter how quiet they are.
    expect(await run(db.listQuietStreamingSessions(afterEvents))).toEqual([streaming.id])
    // Once repaired, the session drops out.
    await run(db.failStaleAssistantChatItems(streaming.id, "closed by sweep"))
    expect(await run(db.listQuietStreamingSessions(afterEvents))).toEqual([])
    await run(db.close)
  })

  it("omits completed transcript shells without renderable content", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/empty-transcript-shells" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "claude-code" }))

    await run(db.appendEvent("session.output", session.id, { role: "user", text: "visible" }))

    const sqlite = new Database(filename)
    const insertShell = sqlite.prepare(
      `insert into chat_items
         (id, session_id, position, role, status, created_at, updated_at)
       values (?, ?, ?, ?, ?, '2026-08-12T00:00:00.000Z', '2026-08-12T00:00:00.000Z')`
    )
    insertShell.run("empty-user", session.id, 1, "user", "complete")
    insertShell.run("empty-assistant", session.id, 2, "assistant", "complete")
    sqlite.close()

    // Filtering happens before LIMIT, so ghost rows cannot consume a page or
    // manufacture `hasMore`/bottom-space state in a virtualized client.
    const page = await run(db.getTranscriptPage(session.id, undefined, 1))
    expect(page.items).toMatchObject([{ role: "user", text: "visible" }])
    expect(page.hasMore).toBe(false)

    const detail = await run(db.getSessionDetail(session.id))
    expect(detail.conversation).toMatchObject([{ role: "user", text: "visible" }])
    await run(db.close)
  })

  it("bounds transcript pages by text size as well as item count", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    expect(await run(db.migrate)).toEqual([])
    const project = await run(db.createProject({ folderPath: "/tmp/transcript-page-budget" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    for (const marker of ["old", "middle", "new"]) {
      await run(
        db.appendEvent("session.output", session.id, {
          role: "user",
          text: `${marker}:${"x".repeat(15_000)}`
        })
      )
    }

    const newest = await run(db.getTranscriptPage(session.id, undefined, 8))
    expect(newest.items).toHaveLength(1)
    expect(newest.items[0]?.text.startsWith("new:")).toBe(true)
    expect(newest).toMatchObject({ hasMore: true, nextBefore: "2" })

    const older = await run(db.getTranscriptPage(session.id, 2, 16))
    expect(older.items).toHaveLength(2)
    expect(older.items[0]?.text.startsWith("old:")).toBe(true)
    expect(older.items[1]?.text.startsWith("middle:")).toBe(true)
    expect(older).toMatchObject({ hasMore: false })
  })

  it("coalescing handles attachments: empty array coalesces, non-empty stays its own row", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    expect(await run(db.migrate)).toEqual([])
    const project = await run(db.createProject({ folderPath: "/tmp/coalesce-attach" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    const meta = await run(db.createFile("a.png", "image/png", "image", Buffer.from([1, 2, 3])))
    const ref = {
      fileId: meta.id,
      name: meta.name,
      mimeType: meta.mimeType,
      sizeBytes: meta.sizeBytes,
      kind: meta.kind
    }

    // An explicit EMPTY attachments array still coalesces (length 0, row stays
    // attachment-free) — same as passing none.
    await run(db.appendConversationItem(session.id, "assistant", "m1", "He", true, []))
    await run(db.appendConversationItem(session.id, "assistant", "m1", "llo", false, []))
    // A chunk CARRYING attachments never coalesces onto/around: it inserts its
    // own row, and a following chunk can't extend it (its attachments != null).
    await run(db.appendConversationItem(session.id, "assistant", "m2", "pic", false, [ref]))
    await run(db.appendConversationItem(session.id, "assistant", "m2", "more", false, []))

    const detail = await run(db.getSessionDetail(session.id))
    expect(detail.conversation.map((item) => [item.role, item.messageId, item.text])).toEqual([
      ["assistant", "m1", "Hello"],
      ["assistant", "m2", "pic"],
      ["assistant", "m2", "more"]
    ])
    expect(detail.conversation[0]?.attachments).toBeUndefined()
    expect(detail.conversation[1]?.attachments).toEqual([ref])
    expect(detail.conversation[2]?.attachments).toBeUndefined()
  })
})

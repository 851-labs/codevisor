import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
  it("coalesces streamed chunks of the same message into one conversation row until one carries attachments", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      expect(await run(db.migrate)).toEqual([])
      const project = await run(db.createProject({ folderPath: "/tmp/coalesce" }))
      const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
      const meta = await run(db.createFile("a.png", "image/png", "image", Buffer.from([1, 2, 3])))
      const ref = {
        fileId: meta.id,
        name: meta.name,
        mimeType: meta.mimeType,
        sizeBytes: meta.sizeBytes,
        kind: meta.kind
      }

      await run(db.appendConversationItem(session.id, "user", "user-1", "tell me", false))
      await run(db.appendConversationItem(session.id, "assistant", "msg-1", "Hel", true))
      await run(db.appendConversationItem(session.id, "assistant", "msg-1", "lo ", true, []))
      await run(db.appendConversationItem(session.id, "assistant", "msg-1", "world", false))
      await run(db.appendConversationItem(session.id, "assistant", "msg-2", "Next", false))
      await run(db.appendConversationItem(session.id, "assistant", "msg-3", "pic", false, [ref]))
      await run(db.appendConversationItem(session.id, "assistant", "msg-3", "more", false, []))
      await run(db.appendConversationItem(session.id, "assistant", undefined, "loose", false))
      await run(db.appendConversationItem(session.id, "assistant", undefined, "loose2", false))
      await run(db.appendConversationItem(session.id, "user", "msg-2", "reply", false))

      const detail = await run(db.getSessionDetail(session.id))
      expect(
        detail.conversation.map((item) => [
          item.role,
          item.messageId,
          item.text,
          item.isGenerating,
          item.attachments
        ])
      ).toEqual([
        ["user", "user-1", "tell me", false, undefined],
        ["assistant", "msg-1", "Hello world", false, undefined],
        ["assistant", "msg-2", "Next", false, undefined],
        ["assistant", "msg-3", "pic", false, [ref]],
        ["assistant", "msg-3", "more", false, undefined],
        ["assistant", "imported-text", "loose", false, undefined],
        ["assistant", "imported-text", "loose2", false, undefined],
        ["user", "msg-2", "reply", false, undefined]
      ])
    } finally {
      await run(db.close)
    }
  })

  it("projects bounded transcript pages and item-scoped details as events arrive", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    try {
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
      expect(details?.entries.map((entry) => entry.payload)).toMatchObject([
        { sessionUpdate: "agent_message_patch", text: "Hello world", offset: 0 },
        { sessionUpdate: "tool_call", toolCallId: "tool-1", title: "Read a file" }
      ])
      expect(details?.eventCursor).toBe(6)
      expect(await run(db.getTranscriptItemDetails(session.id, "missing"))).toBeUndefined()
    } finally {
      await run(db.close)
    }
  })

  it("reuses the original user transcript row when a response retry echoes its message id", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    try {
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
    } finally {
      await run(db.close)
    }
  })
})

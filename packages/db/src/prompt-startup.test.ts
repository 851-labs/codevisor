import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("durable prompt startup", () => {
  it("persists client identity and a waiting response atomically, then adopts the provider turn", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/prompt-startup" }))
      const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
      const echo = await run(
        db.appendEvent("session.output", session.id, {
          role: "user",
          messageId: "client-prompt",
          text: "Again",
          startsTurn: true
        })
      )
      const starting = await run(db.getTranscriptPage(session.id, undefined, 8))
      expect(starting.eventCursor).toBe(echo.subjectRevision)
      expect(starting.items).toMatchObject([
        { role: "user", messageId: "client-prompt", text: "Again", isGenerating: false },
        { role: "assistant", text: "", isGenerating: true }
      ])
      const user = starting.items[0]!
      const assistant = starting.items[1]!
      expect(echo.payload).toMatchObject({ chatItemId: user.id })
      expect((await run(db.getSessionSummary(session.id))).sidebarState).toBe("inProgress")

      // Harness initialization publishes idle metadata before it has a turn.
      await run(db.appendEvent("session.updated", session.id, { runtimeState: "idle" }))
      expect((await run(db.getSessionSummary(session.id))).sidebarState).toBe("inProgress")
      const started = await run(
        db.appendEvent("session.updated", session.id, {
          turnState: "started",
          turnId: "provider-turn"
        })
      )
      expect(started.payload).toMatchObject({ chatItemId: assistant.id })
      expect((await run(db.getTranscriptPage(session.id, undefined, 8))).items).toHaveLength(2)
      // An overlapping start must not steal a row already bound to a turn.
      await run(
        db.appendEvent("session.updated", session.id, {
          turnState: "started",
          turnId: "overlapping-turn"
        })
      )
      expect((await run(db.getTranscriptPage(session.id, undefined, 8))).items.at(-1)?.turnId).toBe(
        "provider-turn"
      )
      await run(
        db.appendEvent("session.updated", session.id, {
          turnState: "ended",
          turnId: "provider-turn",
          stopReason: "end_turn",
          stopDetail: "Done"
        })
      )

      // Identical text is a separate message, while late events keep their owner.
      await run(
        db.appendEvent("session.output", session.id, {
          role: "user",
          messageId: "next-client-prompt",
          text: "Again",
          startsTurn: true
        })
      )
      const late = await run(
        db.appendEvent("session.updated", session.id, {
          turnState: "ended",
          turnId: "provider-turn",
          stopReason: "end_turn",
          stopDetail: "Done"
        })
      )
      expect(late.payload).toMatchObject({ chatItemId: assistant.id })
      const next = await run(db.getTranscriptPage(session.id, undefined, 8))
      expect(
        next.items.filter((item) => item.role === "user").map((item) => item.messageId)
      ).toEqual(["client-prompt", "next-client-prompt"])
      expect(next.items.at(-1)).toMatchObject({ role: "assistant", isGenerating: true })
    } finally {
      await run(db.close)
    }
  })

  it("makes startup failure terminal in history even when no provider turn ever started", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/failed-startup" }))
      const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
      await run(
        db.appendEvent("session.output", session.id, {
          role: "user",
          messageId: "client-prompt",
          text: "Hello",
          startsTurn: true
        })
      )
      const starting = await run(db.getTranscriptPage(session.id, undefined, 8))
      await run(db.appendEvent("session.error", session.id, { message: "Harness failed to start" }))
      const failed = await run(db.getTranscriptPage(session.id, undefined, 8))
      expect(failed.items.map((item) => item.id)).toEqual(starting.items.map((item) => item.id))
      expect(failed.items.at(-1)).toMatchObject({
        role: "assistant",
        isGenerating: false,
        stopDetail: "Harness failed to start"
      })
      expect((await run(db.getSessionSummary(session.id))).sidebarState).toBe("errored")
    } finally {
      await run(db.close)
    }
  })
})

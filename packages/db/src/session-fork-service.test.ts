import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const searchTool = (toolCallId: string) => ({
  sessionUpdate: "tool_call",
  toolCallId,
  title: toolCallId,
  kind: "fetch",
  status: "completed"
})

const answer = (messageId: string, text: string) => ({
  sessionUpdate: "agent_message_chunk",
  messageId,
  content: { type: "text", text }
})

describe("copying a session's transcript into a fork", () => {
  it("gives the fork the whole conversation and its details, then a fork marker", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/fork-source" }))
      const source = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
      const fork = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
      const append = (kind: "session.output" | "session.updated", payload: object) =>
        run(db.appendEvent(kind, source.id, payload))
      await append("session.output", {
        role: "user",
        messageId: "ask",
        startsTurn: true,
        text: "weather?"
      })
      await append("session.updated", { turnId: "t1", turnState: "started" })
      await append("session.output", searchTool("search-sf"))
      await append("session.output", answer("reply", "SF is foggy."))
      await append("session.updated", { stopReason: "end_turn", turnId: "t1", turnState: "ended" })

      await run(
        db.copySessionTranscript(source.id, fork.id, {
          text: "Forked from Weather",
          createdAt: "2026-10-29T20:00:00.000Z"
        })
      )

      const sourcePage = await run(db.getTranscriptPage(source.id, undefined, 8))
      const forkPage = await run(db.getTranscriptPage(fork.id, undefined, 8))
      const shape = (item: (typeof forkPage.items)[number]) => [item.role, item.text, item.origin]
      expect(forkPage.items.map(shape)).toEqual([
        ...sourcePage.items.map(shape),
        ["user", "Forked from Weather", "fork"]
      ])
      expect(forkPage.items.map((item) => item.id)).not.toContain(sourcePage.items[1]?.id)
      const reply = forkPage.items[1]!
      const details = await run(db.getTranscriptItemDetails(fork.id, reply.id))
      expect(details?.entries.length).toBeGreaterThan(0)
      expect(details?.entries.map((entry) => entry.key)).toEqual(
        (await run(db.getTranscriptItemDetails(source.id, sourcePage.items[1]!.id)))?.entries.map(
          (entry) => entry.key
        )
      )
      expect((await run(db.getTranscriptPage(source.id, undefined, 8))).items).toEqual(
        sourcePage.items
      )
    } finally {
      await Effect.runPromise(db.close)
    }
  })
})

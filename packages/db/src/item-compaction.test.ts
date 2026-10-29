import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const compaction = (compactionId: string, status: string) => ({
  sessionUpdate: "context_compaction",
  compactionId,
  status
})

describe("compaction-only turns", () => {
  it("marks turns that only compacted the context, and leaves failed or mixed turns alone", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/compaction-only" }))
      const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
      const append = (kind: "session.output" | "session.updated", payload: object) =>
        run(db.appendEvent(kind, session.id, payload))
      const turn = async (turnId: string, outputs: ReadonlyArray<object>) => {
        await append("session.updated", { turnId, turnState: "started" })
        for (const output of outputs) await append("session.output", output)
        await append("session.updated", { stopReason: "end_turn", turnId, turnState: "ended" })
      }

      await turn("t1", [compaction("c1", "started"), compaction("c1", "completed")])
      await turn("t2", [compaction("c2", "started"), compaction("c2", "failed")])
      await turn("t3", [
        compaction("c3", "completed"),
        { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Done." } }
      ])

      await append("session.updated", { turnId: "t4", turnState: "started" })
      await append("session.output", compaction("c4", "started"))

      const page = await run(db.getTranscriptPage(session.id, undefined, 8))
      expect(page.items.map((item) => item.compaction)).toEqual([
        "completed",
        undefined,
        undefined,
        "started"
      ])
    } finally {
      await Effect.runPromise(db.close)
    }
  })
})

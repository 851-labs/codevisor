import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("@codevisor/db stale assistant items", () => {
  it("closes stale streaming assistant items silently as finished responses", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/close-stale-assistant-items" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "claude-code" }))

    expect(await run(db.closeStaleAssistantChatItems(session.id))).toBe(0)

    await run(
      db.appendEvent("session.updated", session.id, { turnId: "turn-quiet", turnState: "started" })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        content: { type: "text", text: "partial answer" },
        messageId: "answer-quiet",
        sessionUpdate: "agent_message_chunk"
      })
    )
    const stale = (await run(db.getTranscriptPage(session.id, undefined, 8))).items.at(-1)!
    expect(await run(db.closeStaleAssistantChatItems(session.id, stale.id))).toBe(0)

    expect(await run(db.closeStaleAssistantChatItems(session.id))).toBe(1)
    const closed = (await run(db.getTranscriptPage(session.id, undefined, 8))).items.at(-1)!
    // An ordinary finished response: no failure status, nothing to render.
    expect(closed).toMatchObject({
      id: stale.id,
      isGenerating: false,
      stopReason: "end_turn",
      text: "partial answer"
    })
    expect(closed).not.toHaveProperty("stopDetail")
    expect(await run(db.listQuietStreamingSessions(new Date().toISOString()))).toEqual([])

    // The projection pointer is dropped, so later output opens a fresh item
    // instead of reviving the closed one.
    await run(
      db.appendEvent("session.output", session.id, {
        content: { type: "text", text: "later" },
        messageId: "answer-later",
        sessionUpdate: "agent_message_chunk"
      })
    )
    const items = (await run(db.getTranscriptPage(session.id, undefined, 8))).items
    expect(items.at(-1)?.id).not.toBe(stale.id)
    expect(items.at(-1)).toMatchObject({ isGenerating: true, text: "later" })
    await run(db.close)
  })
})

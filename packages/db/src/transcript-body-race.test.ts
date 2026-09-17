import { expect, it } from "vitest"

import { memoryDatabase, run } from "./test-support.js"

it("returns an atomic body block and generation so readers can detect a replacement between pages", async () => {
  const { db, session } = await memoryDatabase()
  await run(
    db.appendEvent("session.output", session.id, {
      sessionUpdate: "agent_message_chunk",
      messageId: "m",
      content: { type: "text", text: "a".repeat(20000) }
    })
  )
  const item = (await run(db.getTranscriptPage(session.id, undefined, 1))).items[0]!
  const first = await run(db.getTranscriptBodyPage(session.id, item.id, "message::m", "text", 0))
  expect(first?.text).toBe("a".repeat(8192))
  await run(
    db.appendEvent("session.output", session.id, {
      sessionUpdate: "assistant_message_finalized",
      messageId: "m",
      markdown: "final"
    })
  )
  const replaced = await run(db.getTranscriptBodyPage(session.id, item.id, "message::m", "text", 0))
  expect(replaced?.text).toBe("final")
  expect(replaced?.revision).not.toBe(first?.revision)
  expect(
    await run(db.getTranscriptBodyPage(session.id, item.id, "message::m", "text", 1))
  ).toBeUndefined()
})

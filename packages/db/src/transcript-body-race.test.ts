import { expect, it, vi } from "vitest"
import { memoryDatabase, run } from "./test-support.js"
const context = vi.hoisted(() => vi.fn())
vi.mock("./transcript-markdown-context.js", () => ({ transcriptMarkdownContext: context }))

it("rejects a body range if the answer is finalized while its markdown context is being indexed", async () => {
  const { db, session } = await memoryDatabase()
  await run(
    db.appendEvent("session.output", session.id, {
      sessionUpdate: "agent_message_chunk",
      messageId: "m",
      content: { type: "text", text: "a".repeat(20000) }
    })
  )
  const item = (await run(db.getTranscriptPage(session.id, undefined, 1))).items[0]!
  const started = Promise.withResolvers<void>()
  const release = Promise.withResolvers<{ prefix: string; leadingText: string }>()
  context.mockImplementation(() => {
    started.resolve()
    return release.promise
  })
  const reading = run(db.getTranscriptBodyPage(session.id, item.id, "message::m", "text", 1))
  const rejected = expect(reading).rejects.toThrow("Transcript changed")
  await started.promise
  await run(
    db.appendEvent("session.output", session.id, {
      sessionUpdate: "assistant_message_finalized",
      messageId: "m",
      markdown: "final"
    })
  )
  release.resolve({ prefix: "", leadingText: "" })
  await rejected
})

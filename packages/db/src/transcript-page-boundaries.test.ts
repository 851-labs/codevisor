import { expect, it } from "vitest"

import { createChatItem, seedStandaloneText, chatAssistantSummary } from "./chat-items.js"
import { memoryDatabase, run } from "./test-support.js"
import { projectTranscriptState, textPatchForEvent } from "./transcript-state.js"

it("keeps parent tool headers across detail pages and respects the serialized byte budget", async () => {
  const { db, session } = await memoryDatabase()
  await run(
    db.appendEvent("session.output", session.id, {
      sessionUpdate: "tool_call",
      toolCallId: "parent",
      title: "p".repeat(700),
      rawOutput: "x".repeat(20000)
    })
  )
  for (let index = 0; index < 34; index++)
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "tool_call",
        toolCallId: `child${index}`,
        parentToolCallId: "parent",
        title: "child"
      })
    )
  const item = (await run(db.getTranscriptPage(session.id, undefined, 1))).items[0]!
  const first = (await run(db.getTranscriptItemDetails(session.id, item.id)))!
  const second = (await run(db.getTranscriptItemDetails(session.id, item.id, first.nextAfter)))!
  expect(second.entries[0]).toMatchObject({
    key: "tool:parent",
    payload: { title: "p".repeat(512), detailResource: { entryKey: "tool:parent" } }
  })
  expect(second.entries).toHaveLength(4)
  const latest = (await run(db.getTranscriptItemDetails(session.id, item.id, "latest")))!
  expect(latest.entries).toHaveLength(33) // 32 entries plus the parent header.
  expect(latest.entries.at(-1)?.key).toBe("tool:child33")
  expect(latest.nextAfter).toBeUndefined()
  expect(latest.previousBefore).toBeTypeOf("string")
  const older = (await run(
    db.getTranscriptItemDetails(session.id, item.id, latest.previousBefore)
  ))!
  expect(older.entries.map((entry) => entry.key)).toEqual([
    "tool:parent",
    "tool:child0",
    "tool:child1"
  ])
  expect(older.previousBefore).toBeUndefined()
  await run(db.appendEvent("session.updated", session.id, { turnState: "ended" }))
  for (const messageId of ["a", "b"])
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        messageId,
        content: { type: "text", text: "中".repeat(24000) }
      })
    )
  const textItem = (await run(db.getTranscriptPage(session.id, undefined, 1))).items.at(-1)!
  const page = (await run(db.getTranscriptItemDetails(session.id, textItem.id)))!
  expect(page.entries).toHaveLength(1)
  expect(Buffer.byteLength(JSON.stringify(page))).toBeLessThan(96 * 1024)
  expect(
    (await run(db.getTranscriptItemDetails(session.id, textItem.id, page.nextAfter)))!.entries
  ).toHaveLength(1)
})

it("exposes migrated text without streaming metadata and seeds standalone content idempotently", async () => {
  const { sqlite, db, session } = await memoryDatabase()
  const itemId = createChatItem(sqlite, session.id, "assistant", "2026-09-16", {
    status: "complete",
    text: "answer",
    planDocument: "p".repeat(25000)
  })
  seedStandaloneText(sqlite, itemId, "")
  seedStandaloneText(sqlite, itemId, "answer")
  sqlite
    .prepare("update transcript_entries set payload = '{}' where item_id = ? and category = 'text'")
    .run(itemId)
  expect(chatAssistantSummary(sqlite, session.id, itemId)).toMatchObject({
    text: "answer",
    textGeneration: 0
  })
  expect(await run(db.getTranscriptItemDetails(session.id, itemId))).toMatchObject({
    entries: expect.arrayContaining([
      expect.objectContaining({ payload: expect.objectContaining({ generation: 0 }) })
    ])
  })
  expect(
    await run(db.getTranscriptBodyPage(session.id, itemId, "imported-text", "text", 0))
  ).toMatchObject({ revision: 0, text: "answer" })
  const event = {
    session_id: session.id,
    revision: 10,
    server_id: "local",
    global_event_id: null,
    kind: "session.output",
    created_at: "2026-09-16",
    payload: "null",
    chat_item_id: itemId
  }
  projectTranscriptState(sqlite, event as never, itemId)
  const payload = { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "new" } }
  projectTranscriptState(sqlite, { ...event, payload: JSON.stringify(payload) } as never, itemId)
  projectTranscriptState(
    sqlite,
    { ...event, revision: 11, payload: JSON.stringify(payload) } as never,
    itemId
  )
  sqlite
    .prepare("update transcript_entries set payload = '{}' where item_id = ? and revision = 11")
    .run(itemId)
  expect(textPatchForEvent(sqlite, itemId, 11, payload)).toMatchObject({
    generation: 0,
    text: "new",
    offset: 3
  })
  await run(
    db.appendEvent("session.output", session.id, {
      sessionUpdate: "plan_document",
      role: "assistant",
      text: "Provider omitted markdown"
    })
  )
})

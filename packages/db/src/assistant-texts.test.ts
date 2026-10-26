import { describe, expect, it } from "vitest"

import { memoryDatabase, run } from "./test-support.js"

const shotUrl = "https://attachments.codevisor.invalid/shot"

const startTurn = async () => {
  const fixture = await memoryDatabase()
  const { db, session } = fixture
  await run(
    db.appendEvent("session.updated", session.id, { turnId: "turn-1", turnState: "started" })
  )
  const output = (payload: Record<string, unknown>) =>
    run(db.appendEvent("session.output", session.id, payload))
  const shot = await run(
    db.createDiskFile({
      id: "shot",
      name: "shot.png",
      mimeType: "image/png",
      sizeBytes: 6,
      sha256: "a".repeat(64),
      kind: "image",
      createdAt: "2026-10-26T00:00:00.000Z"
    })
  )
  return { ...fixture, output, shot }
}

const chunk = (text: string, parentToolCallId?: string) => ({
  sessionUpdate: "agent_message_chunk",
  content: { type: "text", text },
  ...(parentToolCallId === undefined ? {} : { parentToolCallId })
})

const mediaFileIds = (sqlite: Awaited<ReturnType<typeof memoryDatabase>>["sqlite"]) =>
  sqlite.prepare("select file_id from chat_item_media").all()

describe("assistant text rewrites", () => {
  it("lists a streaming turn's open texts until a tool call or a new message closes them", async () => {
    const { db, session, output } = await startTurn()
    await output(chunk("Before the tool"))
    await output(chunk("Inside the child", "child"))

    const open = await run(db.listOpenAssistantTexts(session.id))
    expect(open.map((text) => text.parentToolCallId)).toEqual(["", "child"])

    await output({ sessionUpdate: "tool_call", toolCallId: "tool-1", title: "Read", kind: "read" })
    expect(await run(db.listOpenAssistantTexts(session.id))).toEqual([open[1]])
  })

  it("replaces a closed text with a newer generation and delivers it as a patch", async () => {
    const { db, sqlite, session, output, shot } = await startTurn()
    await output(chunk("Look: ![Shot](build/shot.png)"))
    await output(chunk("Child: ![Shot](build/shot.png)", "child"))
    const [parentText, childText] = await run(db.listOpenAssistantTexts(session.id))
    await output({ sessionUpdate: "tool_call", toolCallId: "tool-1", title: "Read", kind: "read" })

    const rewritten = await output({
      sessionUpdate: "assistant_text_rewritten",
      itemId: parentText!.itemId,
      entryKey: parentText!.entryKey,
      markdown: `Look: ![Shot](${shotUrl})`,
      attachments: [
        {
          fileId: shot.id,
          name: shot.name,
          mimeType: shot.mimeType,
          sizeBytes: shot.sizeBytes,
          kind: shot.kind
        }
      ]
    })
    const child = await output({
      sessionUpdate: "assistant_text_rewritten",
      itemId: childText!.itemId,
      entryKey: childText!.entryKey,
      markdown: `Child: ![Shot](${shotUrl})`
    })

    expect(rewritten.payload).toMatchObject({
      sessionUpdate: "agent_message_patch",
      text: `Look: ![Shot](${shotUrl})`,
      offset: 0,
      generation: 1,
      isFinalized: false
    })
    expect(child.payload).toMatchObject({ parentToolCallId: "child", generation: 1 })
    expect(await run(db.readAssistantText(parentText!.itemId, parentText!.entryKey))).toBe(
      `Look: ![Shot](${shotUrl})`
    )
    expect(mediaFileIds(sqlite)).toEqual([{ file_id: "shot" }])
    expect(await run(db.listOpenAssistantTexts(session.id))).toEqual([childText])
  })

  it("ignores rewrites it cannot place and rewrites a finished message too", async () => {
    const { db, session, output } = await startTurn()
    await output(chunk("Streaming"))
    const [open] = await run(db.listOpenAssistantTexts(session.id))
    await run(db.appendConversationItem(session.id, "user", "user-1", "Seeded", false))
    const page = await run(db.getTranscriptPage(session.id, undefined, 8))
    const seeded = page.items.find((item) => item.role === "user")!
    const seededKey = seeded.textResource!.entryKey

    const unplaced = [
      { itemId: open!.itemId, entryKey: open!.entryKey },
      { itemId: open!.itemId, markdown: "x" },
      { itemId: open!.itemId, entryKey: "missing", markdown: "x" },
      { itemId: "missing", entryKey: open!.entryKey, markdown: "x" },
      { entryKey: open!.entryKey, markdown: "x" }
    ]
    for (const payload of unplaced) {
      const event = await output({ sessionUpdate: "assistant_text_rewritten", ...payload })
      expect(event.payload).toMatchObject({ sessionUpdate: "assistant_text_rewritten" })
    }
    const reseeded = await output({
      sessionUpdate: "assistant_text_rewritten",
      itemId: seeded.id,
      entryKey: seededKey,
      markdown: "Seeded, rewritten"
    })

    expect(await run(db.readAssistantText(open!.itemId, open!.entryKey))).toBe("Streaming")
    expect(reseeded.payload).toMatchObject({ text: "Seeded, rewritten", generation: 1 })
  })
})

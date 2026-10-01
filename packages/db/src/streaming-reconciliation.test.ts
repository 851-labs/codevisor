import { expect, it, vi } from "vitest"

import { memoryDatabase, run } from "./test-support.js"

it("refuses stale candidates after new activity and leaves empty sessions untouched", async () => {
  vi.useFakeTimers({ toFake: ["Date"] })
  try {
    vi.setSystemTime("2026-01-01T00:00:00.000Z")
    const { db, session } = await memoryDatabase()
    const cutoff = "2026-01-01T00:01:00.000Z"
    expect(await run(db.reconcileQuietStreamingSession(session.id, cutoff))).toEqual({
      repaired: 0,
      events: []
    })
    vi.setSystemTime("2026-01-01T00:02:00.000Z")
    await run(
      db.appendEvent("session.updated", session.id, { turnId: "new", turnState: "started" })
    )
    expect(await run(db.reconcileQuietStreamingSession(session.id, cutoff))).toEqual({
      repaired: 0,
      events: []
    })
    expect((await run(db.getTranscriptPage(session.id, undefined, 1))).items.at(-1)).toMatchObject({
      turnId: "new",
      isGenerating: true
    })
  } finally {
    vi.useRealTimers()
  }
})

it.each([false, true])(
  "terminally repairs a quiet turn, including its question (provider identity: %s)",
  async (identified) => {
    const { db, session } = await memoryDatabase()
    await run(
      db.appendEvent("session.updated", session.id, {
        turnState: "started",
        ...(identified ? { turnId: "orphan" } : {})
      })
    )
    if (identified)
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "question",
          questionId: "q",
          questions: [{ id: "choice", question: "Continue?", options: [{ label: "Yes" }] }]
        })
      )
    const result = await run(
      db.reconcileQuietStreamingSession(session.id, "2100-01-01T00:00:00.000Z")
    )
    expect(result.repaired).toBe(1)
    expect(result.events.map((event) => event.kind)).toEqual(
      identified
        ? ["session.output", "session.updated", "session.attention.updated"]
        : ["session.updated", "session.attention.updated"]
    )
    const page = await run(db.getTranscriptPage(session.id, undefined, 1))
    expect(page.items.at(-1)).toMatchObject({ isGenerating: false, stopReason: "end_turn" })
    expect(page.pendingQuestion).toBeUndefined()
    expect(result.events.at(-1)?.subjectRevision).toBe(page.eventCursor)
    expect(
      await run(db.reconcileQuietStreamingSession(session.id, "2100-01-01T00:00:00.000Z"))
    ).toEqual({ repaired: 0, events: [] })
  }
)

it("repairs stranded older rows without ending the latest user message", async () => {
  const { db, session, sqlite } = await memoryDatabase()
  await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
  const orphan = (await run(db.getTranscriptPage(session.id, undefined, 1))).items[0]!
  await run(
    db.appendEvent("session.output", session.id, {
      role: "user",
      text: "later",
      messageId: "later"
    })
  )
  // Persisted legacy shape: the user message is latest but the older row was
  // left streaming by an interrupted process.
  sqlite.prepare("update chat_items set status = 'streaming' where id = ?").run(orphan.id)
  const result = await run(
    db.reconcileQuietStreamingSession(session.id, "2100-01-01T00:00:00.000Z")
  )
  expect(result.repaired).toBe(1)
  expect(result.events.map((event) => event.kind)).toEqual(["session.attention.updated"])
  const page = await run(db.getTranscriptPage(session.id, undefined, 8))
  expect(page.items).toMatchObject([
    { id: orphan.id, isGenerating: false },
    { role: "user", text: "later" }
  ])
})

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
  "terminally repairs a quiet turn and keeps its question waiting (provider identity: %s)",
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
          questions: [
            { id: "choice", question: "Continue?", options: [{ label: "Yes" }], allowsOther: false }
          ]
        })
      )
    const result = await run(
      db.reconcileQuietStreamingSession(session.id, "2100-01-01T00:00:00.000Z")
    )
    expect(result.repaired).toBe(1)
    expect(result.events.map((event) => event.kind)).toEqual([
      "session.updated",
      "session.attention.updated"
    ])
    const page = await run(db.getTranscriptPage(session.id, undefined, 1))
    expect(page.items.at(-1)).toMatchObject({
      isGenerating: false,
      stopReason: "end_turn",
      ...(identified ? { stopKind: "interrupted" } : {})
    })
    expect(page.pendingQuestion?.questionId).toBe(identified ? "q" : undefined)
    expect(result.events.at(-1)?.subjectRevision).toBe(page.eventCursor)
    expect(
      await run(db.reconcileQuietStreamingSession(session.id, "2100-01-01T00:00:00.000Z"))
    ).toEqual({ repaired: 0, events: [] })
  }
)

it("cancels a setup prompt its quiet turn left behind", async () => {
  const { db, session } = await memoryDatabase()
  await run(db.appendEvent("session.updated", session.id, { turnId: "t", turnState: "started" }))
  await run(
    db.appendEvent("session.output", session.id, {
      sessionUpdate: "question",
      questionId: "computer-use",
      questions: [
        {
          id: "computer_use_permissions",
          question: "Allow",
          options: [{ label: "Continue" }],
          allowsOther: false,
          presentation: "computerUsePermissions"
        }
      ]
    })
  )

  const result = await run(
    db.reconcileQuietStreamingSession(session.id, "2100-01-01T00:00:00.000Z")
  )

  expect(result.events.map((event) => event.payload)).toEqual([
    expect.objectContaining({ questionId: "computer-use", outcome: "cancelled" }),
    expect.not.objectContaining({ stopKind: expect.anything() }),
    expect.anything()
  ])
  expect(
    (await run(db.getTranscriptPage(session.id, undefined, 1))).pendingQuestion
  ).toBeUndefined()
})

it("repairs stranded older rows without ending the latest user message", async () => {
  const { db, session, sqlite } = await memoryDatabase()
  await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
  const orphan = (await run(db.getTranscriptPage(session.id, undefined, 1))).items[0]!
  await run(
    db.appendEvent("session.output", session.id, {
      role: "user",
      text: "later",
      messageId: "later",
      startsTurn: true
    })
  )
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

it("leaves a plugin setup card waiting after its turn has ended", async () => {
  const { db, session } = await memoryDatabase()
  await run(db.appendEvent("session.updated", session.id, { turnId: "t", turnState: "started" }))
  await run(
    db.appendEvent("session.updated", session.id, {
      turnId: "t",
      turnState: "ended",
      stopReason: "end_turn"
    })
  )
  await run(
    db.appendEvent("session.output", session.id, {
      sessionUpdate: "question",
      questionId: "plugin-setup:1",
      questions: [
        {
          id: "plugin_setup",
          question: "Sign in to Linear?",
          options: [{ label: "Set Up" }, { label: "Not Now" }],
          allowsOther: false,
          presentation: "pluginSetup"
        }
      ]
    })
  )

  const result = await run(
    db.reconcileQuietStreamingSession(session.id, "2100-01-01T00:00:00.000Z")
  )

  expect(result.events.map((event) => event.kind)).not.toContain("session.output")
  expect((await run(db.getTranscriptPage(session.id, undefined, 1))).pendingQuestion).toMatchObject(
    {
      questionId: "plugin-setup:1"
    }
  )
})

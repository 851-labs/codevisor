import type { TranscriptBodyPage } from "@codevisor/api"
import { expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { readSyncBatch, trimSyncJournal } from "./sync-journal.js"
import { memoryDatabase, run, tempDatabase } from "./test-support.js"

it("continues delivering text deltas after the message exceeds the snapshot preview", async () => {
  const { db, session } = await memoryDatabase()
  await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
  for (const text of ["a".repeat(24_000), "😀 continued", " and still streaming"]) {
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        messageId: "answer",
        content: { type: "text", text }
      })
    )
  }
  const replay = await run(db.readSyncBatch(2, session.id))
  expect(replay.events.map((event) => event.payload)).toMatchObject([
    { sessionUpdate: "agent_message_patch", text: "😀 continued", offset: 24_000 },
    { sessionUpdate: "agent_message_patch", text: " and still streaming", offset: 24_012 }
  ])
})

it("replays short gaps and resnapshots long gaps without deleting transcript content", async () => {
  const { sqlite, db, session } = await memoryDatabase()
  await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
  const originalText = "x".repeat(2500)
  await run(
    db.appendEvent("session.output", session.id, {
      sessionUpdate: "agent_message_chunk",
      messageId: "answer",
      content: { type: "text", text: originalText }
    })
  )

  // Seed already-projected history in one transaction. Retention keeps 2,048
  // rows and checks every 64 revisions; real appends below cross that boundary.
  sqlite.transaction(() => {
    const insert = sqlite.prepare(
      `insert into session_events (session_id, revision, server_id, kind, created_at, payload)
       values (?, ?, 'local', 'session.updated', '2026-09-16T00:00:00.000Z', ?)`
    )
    const payload = JSON.stringify({ title: session.title })
    for (let revision = 3; revision <= 2110; revision++) {
      insert.run(session.id, revision, payload)
    }
    sqlite.prepare("update sessions set revision = 2110 where id = ?").run(session.id)
    sqlite
      .prepare(
        `update sync_watermarks set bytes = (
           select sum(length(cast(payload as blob))) from session_events where session_id = ?
         ) where subject_id = ?`
      )
      .run(session.id, `session:${session.id}`)
  })()

  for (const text of ["y", "z"]) {
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "agent_message_chunk",
        messageId: "answer",
        content: { type: "text", text }
      })
    )
  }
  expect(await run(db.readSyncBatch(0, session.id))).toEqual({
    events: [],
    cursor: 2112,
    requiresSnapshot: true
  })
  const short = await run(db.readSyncBatch(2110, session.id))
  expect(short.requiresSnapshot).toBe(false)
  expect(short.cursor).toBe(2112)
  expect(short.events).toMatchObject([
    {
      id: 2111,
      payload: { sessionUpdate: "agent_message_patch", text: "y", offset: 2500 }
    },
    {
      id: 2112,
      payload: { sessionUpdate: "agent_message_patch", text: "z", offset: 2501 }
    }
  ])
  const page = await run(db.getTranscriptPage(session.id, undefined, 8))
  expect(page.items[0]!.text).toBe(`${originalText}yz`)
  expect(
    sqlite
      .prepare(
        "select count(*) as count, min(revision) as first, max(revision) as last from session_events where session_id = ?"
      )
      .get(session.id)
  ).toEqual({ count: 2048, first: 65, last: 2112 })
  expect(
    sqlite
      .prepare("select floor from sync_watermarks where subject_id = ?")
      .get(`session:${session.id}`)
  ).toEqual({ floor: 64 })
  expect(
    (sqlite.prepare("select count(*) as n from transcript_entries").get() as { n: number }).n
  ).toBe(1)
})

it("replays compact tool metadata and pages the complete oversized body", async () => {
  const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
  const project = await run(db.createProject({ folderPath: "/tmp/journal-body" }))
  const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
  await run(
    db.appendEvent("session.output", session.id, {
      sessionUpdate: "tool_call",
      toolCallId: "large",
      title: "Large output",
      status: "completed",
      rawOutput: "z".repeat(5 * 1024 * 1024)
    })
  )
  const replay = await run(db.readSyncBatch(0, session.id))
  expect(replay.requiresSnapshot).toBe(false)
  expect(Buffer.byteLength(JSON.stringify(replay))).toBeLessThan(4096)
  const item = (await run(db.getTranscriptPage(session.id, undefined, 8))).items[0]!
  const details = await run(db.getTranscriptItemDetails(session.id, item.id))
  expect(Buffer.byteLength(JSON.stringify(details))).toBeLessThan(4096)
  expect(details?.entries[0]?.payload).toMatchObject({
    sessionUpdate: "tool_call",
    toolCallId: "large",
    title: "Large output",
    status: "completed",
    detailResource: { itemId: item.id, entryKey: "tool:large" }
  })
  let position: number | undefined = 0
  let bytes = 0
  do {
    const body: TranscriptBodyPage = (await run(
      db.getTranscriptBodyPage(session.id, item.id, "tool:large", "rawOutput", position)
    ))!
    expect(body.text).toBe("z".repeat(body.text.length))
    expect(body.text.length).toBeLessThanOrEqual(8192)
    bytes += body.text.length
    position = body.nextPosition
  } while (position !== undefined)
  expect(bytes).toBe(5 * 1024 * 1024)
  await run(db.close)
})

it("bounds the global journal and rejects missing or out-of-range delivery cursors", async () => {
  const { sqlite } = await memoryDatabase()
  sqlite.exec("delete from events; delete from sync_watermarks")
  expect(readSyncBatch(sqlite, 0)).toEqual({ events: [], cursor: 0, requiresSnapshot: false })
  expect(readSyncBatch(sqlite, 0, "missing")).toEqual({
    events: [],
    cursor: 0,
    requiresSnapshot: false
  })
  const insert = sqlite.prepare(
    "insert into events (server_id, kind, subject_id, created_at, payload) values ('local', 'project.updated', 'project', '2026-09-16', ?)"
  )
  const first = Number(insert.run("{}").lastInsertRowid)
  expect(readSyncBatch(sqlite, 0).events).toMatchObject([{ id: first }])
  trimSyncJournal(sqlite, 2, 64)
  for (let index = 0; index < 3; index++) {
    const payload = JSON.stringify({ body: "x".repeat(2 * 1024 * 1024) })
    const id = Number(insert.run(payload).lastInsertRowid)
    trimSyncJournal(sqlite, Buffer.byteLength(payload), id)
  }
  expect((sqlite.prepare("select count(*) as n from events").get() as { n: number }).n).toBe(1)
  expect(readSyncBatch(sqlite, first).requiresSnapshot).toBe(true)
  const floor = (
    sqlite.prepare("select floor from sync_watermarks where subject_id = 'global'").get() as {
      floor: number
    }
  ).floor
  expect(readSyncBatch(sqlite, floor).requiresSnapshot).toBe(true)
})

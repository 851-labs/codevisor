import type { NavigationDelta } from "@codevisor/api"
import Database from "better-sqlite3"
import { expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

it("records metadata changes atomically and replays only changed rows after a snapshot", async () => {
  const filename = tempDatabase()
  const db = await run(makeDatabase({ filename, serverId: "local" }))
  try {
    const project = await run(db.createProject({ folderPath: "/tmp/nav-state" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    const snapshot = await run(db.getNavigationSnapshot)
    expect(snapshot.sessions.map((row) => row.id)).toEqual([session.id])
    const raw = new Database(filename)
    try {
      // Simulate a process dying before its route can publish a notification.
      raw.prepare("update sessions set title = 'Persisted rename' where id = ?").run(session.id)
      raw.prepare("update sessions set title = 'Latest rename' where id = ?").run(session.id)
    } finally {
      raw.close()
    }
    const batch = await run(db.readSyncBatch(snapshot.eventCursor))
    expect(batch.requiresSnapshot).toBe(false)
    const changes = batch.events.filter((event) => event.kind === "navigation.changed")
    expect(changes).toHaveLength(1)
    const delta = changes[0]!.payload as NavigationDelta
    expect(delta.sessions).toMatchObject([{ id: session.id, title: "Latest rename" }])
    expect(delta.projects).toEqual([])
    expect(delta.eventCursor).toBeGreaterThan(snapshot.eventCursor)
    expect((await run(db.readSyncBatch(batch.cursor))).events).toEqual([])
  } finally {
    await run(db.close)
  }
})

it("pages a transcript in both directions without gaps or losing the permanent body", async () => {
  const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
  try {
    const project = await run(db.createProject({ folderPath: "/tmp/history-window" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    for (let index = 0; index < 100; index++)
      await run(
        db.appendConversationItem(session.id, "user", `m${index}`, `Message ${index}`, false)
      )
    const latest = await run(db.getTranscriptPage(session.id, undefined, 8))
    expect(latest.items.map((item) => item.sequence)).toEqual([92, 93, 94, 95, 96, 97, 98, 99])
    const older = await run(db.getTranscriptPage(session.id, latest.items[0]!.id, 8))
    expect(older.items.map((item) => item.sequence)).toEqual([84, 85, 86, 87, 88, 89, 90, 91])
    const newer = await run(db.getTranscriptPage(session.id, older.items.at(-1)!.id, 8, true))
    expect(newer.items).toEqual(latest.items)
    expect(newer.hasNewer).toBe(false)
    for (let index = 0; index < 70; index++)
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "tool_call",
          toolCallId: `tool-${index}`,
          title: `Tool ${index}`,
          status: "completed"
        })
      )
    const item = (await run(db.getTranscriptPage(session.id, undefined, 1))).items[0]!
    const first = (await run(db.getTranscriptItemDetails(session.id, item.id)))!
    const second = (await run(db.getTranscriptItemDetails(session.id, item.id, first.nextAfter)))!
    const back = (await run(
      db.getTranscriptItemDetails(session.id, item.id, second.previousBefore)
    ))!
    expect(first.entries).toHaveLength(32)
    expect(second.entries).toHaveLength(32)
    expect(back.entries).toEqual(first.entries)
  } finally {
    await run(db.close)
  }
})

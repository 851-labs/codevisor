import type { TranscriptBodyPage } from "@codevisor/api"
import Database from "better-sqlite3"
import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("persisted transcript state", () => {
  it("pages Unicode text and merged tool state after the source events are unavailable", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/state-pages" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    const text = "a".repeat(8191) + "😀" + "b".repeat(60_000)
    await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
    for (const chunk of [text.slice(0, 9000), text.slice(9000)]) {
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "agent_message_chunk",
          messageId: "answer",
          content: { type: "text", text: chunk }
        })
      )
    }
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "tool_call",
        toolCallId: "read",
        title: "Read file",
        rawInput: { path: "notes.txt" },
        status: "in_progress"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "tool_call_update",
        toolCallId: "read",
        status: "completed",
        rawOutput: { text: "preserved output" }
      })
    )
    await run(db.appendEvent("session.updated", session.id, { turnState: "ended" }))
    const page = await run(db.getTranscriptPage(session.id, undefined, 8))
    const itemId = page.items[0]!.id
    expect(page.items[0]!.textResource?.fields[0]).toMatchObject({
      pageCount: 9,
      sizeBytes: text.length * 2
    })
    const raw = new Database(filename)
    raw.exec("delete from session_events")
    raw.close()
    const details = (await run(db.getTranscriptItemDetails(session.id, itemId)))!
    expect(Buffer.byteLength(JSON.stringify(details))).toBeLessThan(100 * 1024)
    expect(details.entries[0]!.payload).toMatchObject({
      sessionUpdate: "agent_message_patch",
      offset: 0,
      text: text.slice(0, 24_000),
      detailResource: { entryKey: "message::answer", itemId }
    })
    expect(details.entries[1]!.payload).toMatchObject({
      sessionUpdate: "tool_call",
      toolCallId: "read",
      title: "Read file",
      isSnapshot: true,
      rawInput: { path: "notes.txt" },
      status: "completed",
      rawOutput: { text: "preserved output" }
    })
    let position: number | undefined = 0
    let reconstructed = ""
    do {
      const body: TranscriptBodyPage = (await run(
        db.getTranscriptBodyPage(session.id, itemId, "message::answer", "text", position)
      ))!
      reconstructed += body.text
      position = body.nextPosition
    } while (position !== undefined)
    expect(reconstructed).toBe(text)
    await run(db.close)
    const restarted = await run(makeDatabase({ filename, serverId: "local" }))
    expect((await run(restarted.getTranscriptPage(session.id, undefined, 8))).items[0]!.text).toBe(
      text.slice(0, 24_000)
    )
    await run(restarted.close)
  })

  it("resumes a committed migration batch without duplicating text", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/state-migration" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
    const itemId = (await run(db.getTranscriptPage(session.id, undefined, 8))).items[0]!.id
    await run(db.close)
    const raw = new Database(filename)
    const count = 600
    const chunk = "abcdef".repeat(2048)
    const insert =
      raw.prepare(`insert into session_events (session_id, revision, server_id, kind, created_at, payload, chat_item_id)
      values (?, ?, 'local', 'session.output', '2026-09-16T00:00:00.000Z', ?, ?)`)
    raw.transaction(() => {
      for (let index = 0; index < count; index++)
        insert.run(
          session.id,
          index + 2,
          JSON.stringify({
            sessionUpdate: "agent_message_chunk",
            messageId: "answer",
            content: { type: "text", text: chunk }
          }),
          itemId
        )
      raw.prepare("update sessions set revision = ? where id = ?").run(count + 1, session.id)
      raw.prepare("delete from backfill_jobs where id = 'persisted-transcript-state-v1'").run()
      raw.exec(
        "drop table legacy_session_events; drop table legacy_events; drop index delivery_events_subject; drop index delivery_events_item;"
      )
    })()
    raw.close()
    await expect(
      run(
        makeDatabase({
          filename,
          serverId: "local",
          onDataUpgradeProgress(progress) {
            if (
              progress.id === "persisted-transcript-state-v1" &&
              progress.state === "running" &&
              progress.completed >= 256
            ) {
              throw new Error("simulated interruption after durable checkpoint")
            }
          }
        })
      )
    ).rejects.toThrow("simulated interruption")
    const check = new Database(filename)
    const checkpoint = check
      .prepare("select completed from backfill_jobs where id = 'persisted-transcript-state-v1'")
      .get() as { completed: number }
    expect(checkpoint.completed).toBeGreaterThanOrEqual(256)
    expect(checkpoint.completed).toBeLessThan(count)
    check.close()
    const migrated = await run(makeDatabase({ filename, serverId: "local" }))
    const verify = new Database(filename)
    const stored = verify
      .prepare("select sum(length(text)) as size from transcript_text_chunks where item_id = ?")
      .get(itemId) as { size: number }
    expect(stored.size).toBe(count * chunk.length)
    const job = verify
      .prepare(
        "select state, completed, total from backfill_jobs where id = 'persisted-transcript-state-v1'"
      )
      .get()
    expect(job).toEqual({ state: "completed", completed: count + 1, total: count + 1 })
    verify.close()
    await run(migrated.close)
  })
})

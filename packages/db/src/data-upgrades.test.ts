import Database from "better-sqlite3"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { DatabaseError, makeDatabase } from "./index.js"
import { buildV4Fixture, run, tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
  it("reports a reusable blocking data upgrade and installs the canonical schema", async () => {
    const filename = tempDatabase()
    const progress: Array<{
      state: string
      completed: number
      total: number
    }> = []
    const db = await run(
      makeDatabase({
        filename,
        serverId: "local",
        onDataUpgradeProgress: (update) => progress.push(update)
      })
    )

    expect(progress[0]?.state).toBe("running")
    expect(progress.at(-1)).toMatchObject({ state: "completed" })
    expect(progress.at(-1)?.completed).toBe(progress.at(-1)?.total)
    const sqlite = new Database(filename)
    for (const table of ["chat_items", "chat_parts", "session_events", "session_chat_state"]) {
      expect(
        sqlite
          .prepare("select name from sqlite_master where type = 'table' and name = ?")
          .get(table)
      ).toMatchObject({ name: table })
    }
    sqlite.close()
    await Effect.runPromise(db.close)
  })

  it("adopts rows written under a former server identity", async () => {
    // A machine that booted as the default "local" before gaining a real
    // --serverId: its project locations and worktrees were stamped "local".
    const filename = tempDatabase()
    const before = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(before.createProject({ folderPath: "/tmp/adopted-project" }))
    await run(before.createWorktree(project.id, "sushi", "codevisor/sushi"))
    await Effect.runPromise(before.close)

    const after = await run(makeDatabase({ filename, serverId: "stock-cloud" }))
    const adopted = (await run(after.listProjects)).find((candidate) => candidate.id === project.id)
    expect(adopted?.locations).toMatchObject([{ serverId: "stock-cloud" }])
    expect(await run(after.listWorktrees(project.id))).toMatchObject([{ serverId: "stock-cloud" }])
    await Effect.runPromise(after.close)
  })

  it("drops former-identity rows that collide with current-identity twins", async () => {
    // If a location for the same folder was re-created under the new id, the
    // stale "local" row is a duplicate and must not survive adoption.
    const filename = tempDatabase()
    const before = await run(makeDatabase({ filename, serverId: "stock-cloud" }))
    const project = await run(before.createProject({ folderPath: "/tmp/twin-project" }))
    await Effect.runPromise(before.close)

    const sqlite = new Database(filename)
    sqlite
      .prepare(
        `insert into project_locations (id, project_id, server_id, folder_path, created_at)
         values ('stale-location', ?, 'local', '/tmp/twin-project', '2026-01-01T00:00:00.000Z')`
      )
      .run(project.id)
    sqlite.close()

    const after = await run(makeDatabase({ filename, serverId: "stock-cloud" }))
    const adopted = (await run(after.listProjects)).find((candidate) => candidate.id === project.id)
    expect(adopted?.locations).toHaveLength(1)
    expect(adopted?.locations).toMatchObject([{ serverId: "stock-cloud" }])
    await Effect.runPromise(after.close)
  })

  it("backfills transcript pages from an older event log", async () => {
    const filename = tempDatabase()
    buildV4Fixture(filename)
    const sqlite = new Database(filename)
    sqlite
      .prepare(
        "insert into events (server_id, kind, subject_id, created_at, payload) values (?, ?, ?, ?, ?)"
      )
      .run(
        "local",
        "session.output",
        "sess-1",
        "2026-06-01T01:04:00.000Z",
        JSON.stringify({ role: "user", text: "from history" })
      )
    sqlite.close()

    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const page = await run(db.getTranscriptPage("sess-1", undefined, 32))
    expect(page.items).toMatchObject([{ sequence: 0, role: "user", text: "from history" }])

    const migrated = new Database(filename)
    expect(
      migrated
        .prepare("select state, completed, total from backfill_jobs where id = ?")
        .get("canonical-session-chat-v1")
    ).toMatchObject({ state: "completed" })
    migrated.close()
  })

  it("backfills complete legacy transcript rows and blocks a mismatched projection", async () => {
    const filename = tempDatabase()
    const initial = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(initial.createProject({ folderPath: "/tmp/legacy-transcript" }))
    const session = await run(initial.createSession({ projectId: project.id, harnessId: "codex" }))
    const conversationFallback = await run(
      initial.createSession({ projectId: project.id, harnessId: "codex" })
    )
    await Effect.runPromise(initial.close)

    const sqlite = new Database(filename)
    sqlite
      .prepare(
        `insert into transcript_items (
          id, session_id, sequence, role, text, created_at, updated_at,
          is_generating, has_details, turn_id, started_at, ended_at,
          stop_reason, stop_detail, plan_document, attachments, revision
        ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        "legacy-assistant",
        session.id,
        0,
        "assistant",
        "legacy answer",
        "2026-06-01T00:00:00.000Z",
        "2026-06-01T00:01:00.000Z",
        0,
        1,
        "legacy-turn",
        "2026-06-01T00:00:00.000Z",
        "2026-06-01T00:01:00.000Z",
        "end_turn",
        "done",
        "legacy plan",
        '[{"fileId":"file-1","name":"a.txt","mimeType":"text/plain","sizeBytes":1,"kind":"document"}]',
        4
      )
    sqlite
      .prepare(
        `insert into transcript_items (
          id, session_id, sequence, role, text, created_at, updated_at,
          is_generating, has_details, turn_id, started_at, ended_at,
          stop_reason, stop_detail, plan_document, attachments, revision
        ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        "legacy-user",
        session.id,
        1,
        "user",
        "legacy question",
        "2026-06-01T00:02:00.000Z",
        "2026-06-01T00:02:00.000Z",
        1,
        0,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        1
      )
    sqlite
      .prepare(
        `insert into conversation_items (
          id, session_id, role, text, created_at, is_generating, message_id, attachments
        ) values (?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        "legacy-conversation",
        conversationFallback.id,
        "user",
        "conversation fallback",
        "2026-06-01T00:03:00.000Z",
        1,
        "legacy-message",
        '[{"fileId":"file-2","name":"b.txt","mimeType":"text/plain","sizeBytes":2,"kind":"document"}]'
      )
    sqlite
      .prepare("insert into transcript_routes (session_id, route_key, item_id) values (?, ?, ?)")
      .run(session.id, "turn:legacy-turn", "legacy-assistant")
    sqlite
      .prepare(
        `insert into events (
          server_id, kind, subject_id, created_at, payload, transcript_item_id
        ) values (?, ?, ?, ?, ?, ?)`
      )
      .run(
        "local",
        "session.output",
        session.id,
        "2026-06-01T00:00:30.000Z",
        JSON.stringify({ role: "assistant", text: "legacy answer" }),
        "legacy-assistant"
      )
    sqlite
      .prepare("update backfill_jobs set state = 'failed', completed = 0 where id = ?")
      .run("canonical-session-chat-v1")
    sqlite.close()

    const migrated = await run(makeDatabase({ filename, serverId: "local" }))
    const page = await run(migrated.getTranscriptPage(session.id, undefined, 8))
    expect(page.items[0]).toMatchObject({
      id: "legacy-assistant",
      text: "legacy answer",
      planDocument: "legacy plan",
      attachments: [
        {
          fileId: "file-1",
          name: "a.txt",
          mimeType: "text/plain",
          sizeBytes: 1,
          kind: "document"
        }
      ],
      stopDetail: "done",
      stopReason: "end_turn",
      turnId: "legacy-turn"
    })
    expect(page.items[1]).toMatchObject({
      id: "legacy-user",
      isGenerating: true,
      text: "legacy question"
    })
    expect(
      (await run(migrated.getSessionDetail(conversationFallback.id))).conversation[0]
    ).toMatchObject({
      isGenerating: true,
      text: "conversation fallback"
    })
    const details = await run(migrated.getTranscriptItemDetails(session.id, "legacy-assistant"))
    expect(details?.events).toHaveLength(1)
    await Effect.runPromise(migrated.close)

    const corrupted = new Database(filename)
    corrupted
      .prepare("update chat_parts set text = 'corrupt' where item_id = ? and kind = 'text'")
      .run("legacy-assistant")
    corrupted
      .prepare("update backfill_jobs set state = 'failed' where id = ?")
      .run("canonical-session-chat-v1")
    corrupted.close()

    const progress: Array<{ state: string; error?: string | undefined }> = []
    await expect(
      run(
        makeDatabase({
          filename,
          serverId: "local",
          onDataUpgradeProgress: (update) => progress.push(update)
        })
      )
    ).rejects.toBeInstanceOf(DatabaseError)
    expect(progress.at(-1)).toMatchObject({ state: "failed" })
    expect(progress.at(-1)?.error).toContain("verification failed")
  })
})

import Database from "better-sqlite3"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { DatabaseError, makeDatabase } from "./index.js"
import { buildV4Fixture, run, tempDatabase } from "./test-support.js"

describe("@codevisor/db project and archive upgrades", () => {
  it("backfills archived timestamps for rows archived before the column existed", async () => {
    const filename = tempDatabase()
    buildV4Fixture(filename)
    // Mark the pre-existing rows archived the way the old schema could: a bare
    // boolean with no moment attached.
    const legacy = new Database(filename)
    legacy.exec(`
      update sessions set is_archived = 1 where id = 'sess-1';
      update workspaces set is_archived = 1 where id = 'ws-1';
    `)
    legacy.close()

    const db = await run(makeDatabase({ filename, serverId: "machine-a" }))

    const session = await run(db.getSessionSummary("sess-1"))
    expect(session.isArchived).toBe(true)
    // A timestamp must exist so the row can be sorted and labelled in the
    // archived section rather than sinking to the bottom forever...
    expect(session.archivedAt).toBeDefined()
    // ...but it must not claim the chat was archived at migration time.
    expect(session.archivedAt?.startsWith("2026-06-01")).toBe(true)

    const project = (await run(db.listProjects)).find((candidate) => candidate.id === "ws-1")
    expect(project?.isArchived).toBe(true)
    expect(project?.archivedAt).toBeDefined()

    await run(db.close)
  })

  it("migrates a v4 database to projects without losing session children", async () => {
    const filename = tempDatabase()
    buildV4Fixture(filename)

    const db = await run(makeDatabase({ filename, serverId: "machine-a" }))

    const projects = await run(db.listProjects)
    expect(projects).toHaveLength(1)
    expect(projects[0]).toMatchObject({ id: "ws-1", name: "Codevisor", origin: "codevisor" })
    expect(projects[0]?.locations).toEqual([
      {
        id: "ws-1",
        projectId: "ws-1",
        serverId: "machine-a",
        folderPath: "/tmp/codevisor",
        createdAt: "2026-06-01T00:00:00.000Z"
      }
    ])

    const detail = await run(db.getSessionDetail("sess-1"))
    expect(detail.session).toMatchObject({
      projectId: "ws-1",
      harnessId: "codex",
      agentSessionId: "agent-1",
      cwd: "/tmp/codevisor"
    })
    expect(detail.session.worktreeName).toBeUndefined()
    expect(detail.conversation.map((item) => item.text)).toEqual(["hello"])
    expect((await run(db.getTranscriptPage("sess-1", undefined, 32))).items).toMatchObject([
      { role: "user", text: "hello" }
    ])
    expect(detail.promptQueue.map((item) => item.text)).toEqual(["queued"])
    expect(await run(db.getSessionActionResult("sess-1", "action-1"))).toEqual({})
    expect(await run(db.getSessionConfigSelections("sess-1"))).toEqual({})

    const sqlite = new Database(filename)
    expect(
      (
        sqlite.prepare("select title_is_user_set from sessions where id = 'sess-1'").get() as {
          title_is_user_set: number
        }
      ).title_is_user_set
    ).toBe(1)
    expect(
      JSON.parse(
        (
          sqlite.prepare("select payload from events where subject_id = 'sess-1'").get() as {
            payload: string
          }
        ).payload
      )
    ).toMatchObject({ origin: "codevisor" })
    expect(
      JSON.parse(
        (
          sqlite
            .prepare("select payload from session_events where session_id = 'sess-1'")
            .get() as { payload: string }
        ).payload
      )
    ).toMatchObject({ origin: "codevisor" })
    // Migration 5 dropped the legacy project-shaped `workspaces` table;
    // migration 21 reuses the freed name for empty pane workspaces, and adds
    // the sessions binding column.
    const workspaceColumns = (
      sqlite.pragma("table_info(workspaces)") as ReadonlyArray<{ readonly name: string }>
    ).map((column) => column.name)
    expect(workspaceColumns).toContain("project_id")
    expect(workspaceColumns).not.toContain("folder_path")
    expect(workspaceColumns).not.toContain("symbol_name")
    expect(
      (sqlite.pragma("table_info(projects)") as ReadonlyArray<{ readonly name: string }>).map(
        (column) => column.name
      )
    ).not.toContain("symbol_name")
    expect(sqlite.prepare("select count(*) as count from workspaces").get()).toEqual({ count: 0 })
    // Migration 22 added the workspace scratchpad table; migration 33 dropped
    // it again when the notes feature was removed. A fresh migrate run still
    // creates it on the way through, so only the end state matters here — the
    // table is gone and its already-logged events went with it.
    expect(
      sqlite
        .prepare("select name from sqlite_master where type = 'table' and name = 'workspace_notes'")
        .get()
    ).toBeUndefined()
    expect(
      sqlite
        .prepare("select count(*) as count from events where kind = 'workspace.notes.updated'")
        .get()
    ).toEqual({ count: 0 })
    expect(
      (sqlite.pragma("table_info(sessions)") as ReadonlyArray<{ readonly name: string }>).map(
        (column) => column.name
      )
    ).toEqual(expect.arrayContaining(["workspace_id", "config_selections"]))
    expect(sqlite.pragma("foreign_key_check")).toEqual([])
    sqlite.close()

    expect(await run(db.migrate)).toEqual([])
    await Effect.runPromise(db.close)
  })

  it("refuses to migrate a database with orphaned child rows", async () => {
    const filename = tempDatabase()
    buildV4Fixture(filename)
    // With enforcement off an orphan can sneak in; the migration's
    // foreign_key_check must catch it.
    const sqlite = new Database(filename)
    sqlite.pragma("foreign_keys = OFF")
    sqlite
      .prepare(
        `insert into sessions (id, workspace_id, server_id, harness_id, title, origin, is_archived, created_at)
         values ('orphan', 'missing-workspace', 'local', 'codex', 'Orphan', 'codevisor', 0, '2026-06-01T02:00:00.000Z')`
      )
      .run()
    sqlite.close()

    await expect(run(makeDatabase({ filename, serverId: "local" }))).rejects.toBeInstanceOf(
      DatabaseError
    )
  })
})

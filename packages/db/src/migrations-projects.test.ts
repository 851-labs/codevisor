import Database from "better-sqlite3"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { DatabaseError, makeDatabase } from "./index.js"
import { buildV4Fixture, run, tempDatabase } from "./test-support.js"

/// Column names of one table, read straight from the file so schema
/// assertions do not depend on the service's own mapping.
const sqliteColumns = (filename: string, table: string): ReadonlyArray<string> => {
  const sqlite = new Database(filename)
  try {
    return (sqlite.pragma(`table_info(${table})`) as ReadonlyArray<{ readonly name: string }>).map(
      (column) => column.name
    )
  } finally {
    sqlite.close()
  }
}

describe("@codevisor/db project and archive upgrades", () => {
  it("moves archive state onto the workspace and closes individually archived chats", async () => {
    const filename = tempDatabase()
    // Build modern state through the public API, then rewind migration 50 and
    // re-create the pre-50 archive columns so the upgrade runs for real.
    const seed = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(seed.createProject({ folderPath: "/tmp/archive-upgrade" }))
    const retired = await run(seed.createProject({ folderPath: "/tmp/retired-project" }))
    const liveWorkspace = await run(
      seed.upsertWorkspace({ projectId: project.id, name: "live", hasCustomName: false })
    )
    const archivedWorkspace = await run(
      seed.upsertWorkspace({
        projectId: project.id,
        name: "archived",
        hasCustomName: false,
        isArchived: true
      })
    )
    const retiredWorkspace = await run(
      seed.upsertWorkspace({ projectId: retired.id, name: "retired", hasCustomName: false })
    )
    const closedByHand = await run(
      seed.createSession({ projectId: project.id, harnessId: "codex" })
    )
    const wentWithWorkspace = await run(
      seed.createSession({ projectId: project.id, harnessId: "codex" })
    )
    await run(seed.setSessionWorkspace(closedByHand.id, liveWorkspace.id))
    await run(seed.setSessionWorkspace(wentWithWorkspace.id, archivedWorkspace.id))
    await run(seed.close)

    const sqlite = new Database(filename)
    sqlite.exec(`
      alter table sessions add column is_archived integer not null default 0;
      alter table sessions add column archived_at text;
      alter table sessions add column archive_cascade_from text;
      alter table projects add column is_archived integer not null default 0;
      alter table projects add column archived_at text;
      alter table workspaces add column archive_cascade_from text;
      alter table archived_worktrees drop column state;
      delete from schema_migrations where id = 50;
    `)
    const archiveSession = sqlite.prepare(
      "update sessions set is_archived = 1, archived_at = '2026-06-01T00:00:00.000Z' where id = ?"
    )
    archiveSession.run(closedByHand.id)
    archiveSession.run(wentWithWorkspace.id)
    sqlite
      .prepare(
        "update projects set is_archived = 1, archived_at = '2026-06-02T00:00:00.000Z' where id = ?"
      )
      .run(retired.id)
    sqlite.close()

    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const panes = await run(db.listWorkspacePanes)
    const workspaces = await run(db.listWorkspaces)

    // Archived on its own means the user closed that tab, so the pane goes.
    expect(panes.some((pane) => pane.resourceId === closedByHand.id)).toBe(false)
    // Archived along with its workspace is not a closed tab: the workspace now
    // carries the archive, and restoring it must bring this tab back.
    expect(panes.some((pane) => pane.resourceId === wentWithWorkspace.id)).toBe(true)

    // An archived project pushes its state down onto the workspaces, which are
    // the only rows that still carry it.
    expect(workspaces.find((w) => w.id === retiredWorkspace.id)?.isArchived).toBe(true)
    expect(workspaces.find((w) => w.id === retiredWorkspace.id)?.archivedAt).toBe(
      "2026-06-02T00:00:00.000Z"
    )
    // Workspaces in a live project are untouched.
    expect(workspaces.find((w) => w.id === liveWorkspace.id)?.isArchived).toBe(false)
    expect(workspaces.find((w) => w.id === archivedWorkspace.id)?.isArchived).toBe(true)

    const columns = (name: string) =>
      (sqliteColumns(filename, name) as ReadonlyArray<string>).join(",")
    expect(columns("sessions")).not.toContain("is_archived")
    expect(columns("projects")).not.toContain("is_archived")
    expect(columns("workspaces")).not.toContain("archive_cascade_from")
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
        isGitRepository: false,
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
          sqlite.prepare("select payload from legacy_events where subject_id = 'sess-1'").get() as {
            payload: string
          }
        ).payload
      )
    ).toMatchObject({ origin: "codevisor" })
    expect(
      JSON.parse(
        (
          sqlite
            .prepare("select payload from legacy_session_events where session_id = 'sess-1'")
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

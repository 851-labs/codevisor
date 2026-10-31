import Database from "better-sqlite3"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { nameRows } from "./common-rows.js"
import { DatabaseError, makeDatabase } from "./index.js"
import { buildV4Fixture, run, tempDatabase } from "./test-support.js"

const tableColumns = (sqlite: Database.Database, table: string): ReadonlyArray<string> =>
  nameRows
    .all(sqlite.prepare(`select name from pragma_table_info(?)`).all(table))
    .map((column) => column.name)

const sqliteColumns = (filename: string, table: string): ReadonlyArray<string> => {
  const sqlite = new Database(filename)
  try {
    return tableColumns(sqlite, table)
  } finally {
    sqlite.close()
  }
}

describe("@codevisor/db project and archive upgrades", () => {
  it("moves archive state onto the workspace and closes individually archived chats", async () => {
    const filename = tempDatabase()
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
    try {
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
    } finally {
      sqlite.close()
    }

    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const panes = await run(db.listWorkspacePanes)
    const workspaces = await run(db.listWorkspaces)

    expect(panes.some((pane) => pane.resourceId === closedByHand.id)).toBe(false)
    expect(panes.some((pane) => pane.resourceId === wentWithWorkspace.id)).toBe(true)

    expect(workspaces.find((w) => w.id === retiredWorkspace.id)?.isArchived).toBe(true)
    expect(workspaces.find((w) => w.id === retiredWorkspace.id)?.archivedAt).toBe(
      "2026-06-02T00:00:00.000Z"
    )
    expect(workspaces.find((w) => w.id === liveWorkspace.id)?.isArchived).toBe(false)
    expect(workspaces.find((w) => w.id === archivedWorkspace.id)?.isArchived).toBe(true)

    const columns = (name: string) => sqliteColumns(filename, name).join(",")
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
    expect((await run(db.getSessionSummary("sess-1"))).configSelections).toBeUndefined()

    const sqlite = new Database(filename)
    try {
      expect(
        sqlite.prepare("select title_is_user_set from sessions where id = 'sess-1'").get()
      ).toEqual({ title_is_user_set: 1 })
      const workspaceColumns = tableColumns(sqlite, "workspaces")
      expect(workspaceColumns).toContain("project_id")
      expect(workspaceColumns).not.toContain("folder_path")
      expect(workspaceColumns).not.toContain("symbol_name")
      expect(tableColumns(sqlite, "projects")).not.toContain("symbol_name")
      expect(sqlite.prepare("select count(*) as count from workspaces").get()).toEqual({ count: 0 })
      expect(
        sqlite
          .prepare(
            "select name from sqlite_master where type = 'table' and name = 'workspace_notes'"
          )
          .get()
      ).toBeUndefined()
      expect(
        sqlite
          .prepare("select count(*) as count from events where kind = 'workspace.notes.updated'")
          .get()
      ).toEqual({ count: 0 })
      expect(tableColumns(sqlite, "sessions")).toEqual(
        expect.arrayContaining(["workspace_id", "config_selections"])
      )
      expect(sqlite.pragma("foreign_key_check")).toEqual([])
    } finally {
      sqlite.close()
    }

    expect(await run(db.migrate)).toEqual([])
    await Effect.runPromise(db.close)
  })

  it("refuses to migrate a database with orphaned child rows", async () => {
    const filename = tempDatabase()
    buildV4Fixture(filename)
    const sqlite = new Database(filename)
    try {
      sqlite.pragma("foreign_keys = OFF")
      sqlite
        .prepare(
          `insert into sessions (id, workspace_id, server_id, harness_id, title, origin, is_archived, created_at)
         values ('orphan', 'missing-workspace', 'local', 'codex', 'Orphan', 'codevisor', 0, '2026-06-01T02:00:00.000Z')`
        )
        .run()
    } finally {
      sqlite.close()
    }

    await expect(run(makeDatabase({ filename, serverId: "local" }))).rejects.toBeInstanceOf(
      DatabaseError
    )
  })
})

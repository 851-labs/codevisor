import Database from "better-sqlite3"
import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("native config safety", () => {
  it("stores one-time backups with first-write-wins semantics", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      expect(await run(db.getNativeConfigBackup("/home/u/.claude.json"))).toBeUndefined()
      await run(
        db.saveNativeConfigBackup({
          backupPath: "/data/backups/abc-.claude.json",
          createdAt: "2026-07-20T00:00:00.000Z",
          filePath: "/home/u/.claude.json"
        })
      )
      await run(
        db.saveNativeConfigBackup({
          backupPath: "/data/backups/later.json",
          createdAt: "2026-07-21T00:00:00.000Z",
          filePath: "/home/u/.claude.json"
        })
      )
      expect(await run(db.getNativeConfigBackup("/home/u/.claude.json"))).toEqual({
        backupPath: "/data/backups/abc-.claude.json",
        createdAt: "2026-07-20T00:00:00.000Z",
        filePath: "/home/u/.claude.json"
      })
    } finally {
      await run(db.close)
    }
  })

  it("parks removals and marks them restored", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const removal = await run(
        db.saveNativeMcpRemoval({
          configPath: "/home/u/.claude.json",
          fragment: JSON.stringify({ command: "docs-mcp" }),
          harnessId: "claude-code",
          serverName: "docs"
        })
      )
      expect(removal).toMatchObject({
        configPath: "/home/u/.claude.json",
        fragment: JSON.stringify({ command: "docs-mcp" }),
        harnessId: "claude-code",
        serverName: "docs"
      })

      expect(await run(db.listNativeMcpRemovals())).toHaveLength(1)
      await run(db.markNativeMcpRemovalRestored(removal.id))
      expect(await run(db.listNativeMcpRemovals())).toHaveLength(0)
    } finally {
      await run(db.close)
    }
  })

  it("canonicalizes session ids to lowercase and matches either case", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ name: "Case", folderPath: "/tmp/case" }))
    const upper = "AB12CD34-EF56-4789-A012-3456789ABCDE"
    const lower = upper.toLowerCase()

    const created = await run(
      db.createSession({ id: upper, projectId: project.id.toUpperCase(), harnessId: "codex" })
    )
    expect(created.id).toBe(lower)
    expect(created.projectId).toBe(project.id)

    expect((await run(db.getSessionSummary(upper))).id).toBe(lower)
    const renamed = await run(db.updateSession(upper, { title: "Renamed" }))
    expect(renamed.title).toBe("Renamed")
    expect(await run(db.listSessions)).toHaveLength(1)

    const queued = await run(db.createPromptQueueItem(upper, "hello", []))
    expect(await run(db.listPromptQueue(lower))).toMatchObject([{ id: queued.id, text: "hello" }])

    await run(db.deleteSession(upper))
    expect(await run(db.listSessions)).toHaveLength(0)
    await run(db.close)
  })

  it("merges case-twin sessions when the canonical ids migration runs", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ name: "Twins", folderPath: "/tmp/twins" }))
    await run(db.close)

    const lowerA = "aaaaaaaa-1111-4111-8111-111111111111"
    const upperA = lowerA.toUpperCase()
    const lowerB = "bbbbbbbb-2222-4222-8222-222222222222"
    const upperB = lowerB.toUpperCase()
    const lowerC = "cccccccc-3333-4333-8333-333333333333"
    const upperC = lowerC.toUpperCase()
    const sqlite = new Database(filename)
    const insertSession = sqlite.prepare(
      `insert into sessions (id, project_id, server_id, harness_id, title, origin, created_at, updated_at)
       values (?, ?, 'local', 'codex', ?, 'codevisor', ?, ?)`
    )
    insertSession.run(
      lowerA,
      project.id,
      "Original A",
      "2026-07-01T00:00:00.000Z",
      "2026-07-01T01:00:00.000Z"
    )
    insertSession.run(
      upperA,
      project.id,
      "Phantom A",
      "2026-07-02T00:00:00.000Z",
      "2026-07-02T01:00:00.000Z"
    )
    insertSession.run(
      lowerB,
      project.id,
      "Original B",
      "2026-07-03T00:00:00.000Z",
      "2026-07-03T02:00:00.000Z"
    )
    insertSession.run(
      upperB,
      project.id,
      "Fork B",
      "2026-07-03T00:30:00.000Z",
      "2026-07-03T01:00:00.000Z"
    )
    insertSession.run(
      lowerC,
      project.id,
      "Older C",
      "2026-07-04T00:00:00.000Z",
      "2026-07-04T01:00:00.000Z"
    )
    insertSession.run(
      upperC,
      project.id,
      "Newer C",
      "2026-07-04T00:30:00.000Z",
      "2026-07-04T02:00:00.000Z"
    )
    const insertChatItem = sqlite.prepare(
      `insert into chat_items (id, session_id, position, role, status, created_at, updated_at)
       values (?, ?, 0, 'user', 'complete', '2026-07-01T00:01:00.000Z', '2026-07-01T00:01:00.000Z')`
    )
    insertChatItem.run("item-a", lowerA)
    insertChatItem.run("item-b-original", lowerB)
    insertChatItem.run("item-b-fork", upperB)
    const insertChatText = sqlite.prepare(
      `insert into chat_parts (id, item_id, position, kind, text, revision)
       values (?, ?, 0, 'text', ?, 1)`
    )
    insertChatText.run("part-a", "item-a", "prompt A")
    insertChatText.run("part-b-original", "item-b-original", "original prompt B")
    insertChatText.run("part-b-fork", "item-b-fork", "fork prompt B")
    sqlite.exec(`
      alter table sessions add column is_archived integer not null default 0;
      alter table sessions add column archived_at text;
      alter table sessions add column archive_cascade_from text;
      alter table projects add column is_archived integer not null default 0;
      alter table projects add column archived_at text;
      alter table workspaces add column archive_cascade_from text;
      alter table archived_worktrees drop column state;
      delete from schema_migrations where id in (30, 50);
    `)
    sqlite.close()

    const reopened = await run(makeDatabase({ filename, serverId: "local" }))
    const sessions = await run(reopened.listSessions)

    const pairA = sessions.filter((session) => session.id.toLowerCase() === lowerA)
    expect(pairA).toHaveLength(1)
    expect(pairA[0]).toMatchObject({ id: lowerA, title: "Original A" })

    const canonicalB = sessions.find((session) => session.id === lowerB)
    expect(canonicalB).toMatchObject({ title: "Original B" })
    const forkB = sessions.find((session) => session.title === "Fork B" && session.id !== lowerB)
    expect(forkB).toBeDefined()
    expect(forkB?.id).toBe(forkB?.id.toLowerCase())
    const forkDetail = await run(reopened.getSessionDetail(forkB!.id))
    expect(forkDetail.conversation).toHaveLength(1)

    const pairC = sessions.filter((session) => session.id.toLowerCase() === lowerC)
    expect(pairC).toHaveLength(1)
    expect(pairC[0]).toMatchObject({ id: lowerC, title: "Newer C" })

    expect(sessions).toHaveLength(4)
    for (const session of sessions) {
      expect(session.id).toBe(session.id.toLowerCase())
    }
    await run(reopened.close)
  })
})

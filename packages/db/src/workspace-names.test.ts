import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { rewindOneNameSql, rewindWorkspaceNamesSql, run, tempDatabase } from "./test-support.js"

const openDatabase = async (filename = tempDatabase()) => {
  const db = await run(makeDatabase({ filename, serverId: "local" }))
  onTestFinished(() => run(db.close))
  const project = await run(db.createProject({ folderPath: "/tmp/workspace-names" }))
  const workspace = (name: string, hasCustomName = false) =>
    run(db.upsertWorkspace({ projectId: project.id, name, hasCustomName }))
  const chat = (workspaceId: string, title?: string) =>
    run(
      db.createSession({
        projectId: project.id,
        harnessId: "codex",
        workspaceId,
        ...(title === undefined ? {} : { title })
      })
    )
  const rename = (sessionId: string, title: string) =>
    run(db.updateSession(sessionId, { title, titleIntent: "rename" }))
  const autoTitle = (sessionId: string, title: string) =>
    run(db.updateSessionTitleFromHarness(sessionId, title))
  const renameWorkspace = (workspaceId: string, name: string, hasCustomName = true) =>
    run(db.updateWorkspace(workspaceId, { name, hasCustomName }))
  return { db, workspace, chat, rename, autoTitle, renameWorkspace }
}

const nameOf = async (db: CodevisorDatabaseService, workspaceId: string): Promise<string> =>
  (await run(db.listWorkspaces)).find((workspace) => workspace.id === workspaceId)?.name ?? ""

const titleOf = async (db: CodevisorDatabaseService, sessionId: string): Promise<string> =>
  (await run(db.getSessionSummary(sessionId))).title

const reopen = async (filename: string, drift: (sqlite: Database.Database) => void) => {
  const sqlite = new Database(filename)
  drift(sqlite)
  sqlite.close()
  const db = await run(makeDatabase({ filename, serverId: "local" }))
  onTestFinished(() => run(db.close))
  return db
}

describe("workspace names", () => {
  it("follow the main chat's title once it has a real one", async () => {
    const { db, workspace, chat, autoTitle } = await openDatabase()
    const home = await workspace("quesadilla-5480")
    const main = await chat(home.id)
    const side = await chat(home.id, "Side question")
    expect(await nameOf(db, home.id)).toBe("quesadilla-5480")

    await autoTitle(main.id, "Fix the login bug")
    await autoTitle(side.id, "Another side question")

    expect(await nameOf(db, home.id)).toBe("Fix the login bug")
    expect(await titleOf(db, side.id)).toBe("Another side question")
  })

  it("take a titled chat's name as soon as it becomes the main chat", async () => {
    const { db, workspace, chat } = await openDatabase()
    const home = await workspace("quesadilla-5480")

    await chat(home.id, "Fix the login bug (fork)")

    expect(await nameOf(db, home.id)).toBe("Fix the login bug (fork)")
  })

  it("rename the main chat when the workspace is renamed, and outrank harness titles", async () => {
    const { db, workspace, chat, autoTitle, renameWorkspace } = await openDatabase()
    const home = await workspace("quesadilla-5480")
    const main = await chat(home.id, "had the orange soda drink for lunch")
    const side = await chat(home.id, "Side question")

    await renameWorkspace(home.id, "macro")
    await autoTitle(main.id, "Logged lunch")

    expect(await nameOf(db, home.id)).toBe("macro")
    expect(await titleOf(db, main.id)).toBe("macro")
    expect(await titleOf(db, side.id)).toBe("Side question")
  })

  it("follow a main chat renamed by hand, even after a workspace rename", async () => {
    const { db, workspace, chat, rename, autoTitle, renameWorkspace } = await openDatabase()
    const home = await workspace("quesadilla-5480")
    const main = await chat(home.id)
    await renameWorkspace(home.id, "macro")

    await rename(main.id, "Lunch log")
    await autoTitle(main.id, "Logged lunch")

    expect(await nameOf(db, home.id)).toBe("Lunch log")
    expect(await titleOf(db, main.id)).toBe("Lunch log")
    const renamed = (await run(db.listWorkspaces)).find(({ id }) => id === home.id)
    expect(renamed?.hasCustomName).toBe(true)
  })

  it("can't be replaced by an automatic name while the main chat has a title", async () => {
    const { db, workspace, chat, renameWorkspace } = await openDatabase()
    const home = await workspace("quesadilla-5480")
    const main = await chat(home.id, "Fix the login bug")

    await renameWorkspace(home.id, "crispy-red-velvet-cake-3206", false)

    expect(await nameOf(db, home.id)).toBe("Fix the login bug")
    expect(await titleOf(db, main.id)).toBe("Fix the login bug")
  })

  it("pass a hand-picked name on to the chat that becomes the main chat", async () => {
    const { db, workspace, chat, autoTitle, renameWorkspace } = await openDatabase()
    const home = await workspace("quesadilla-5480")
    const main = await chat(home.id, "Fix the login bug")
    const side = await chat(home.id, "Side question")
    await renameWorkspace(home.id, "macro")

    await run(db.deleteSession(main.id))
    await autoTitle(side.id, "Another side question")

    expect(await nameOf(db, home.id)).toBe("macro")
    expect(await titleOf(db, side.id)).toBe("macro")
  })

  it("are backfilled from each workspace's main chat", async () => {
    const filename = tempDatabase()
    const before = await openDatabase(filename)
    const titled = await before.workspace("quesadilla-5480")
    const untitled = await before.workspace("crispy-red-velvet-cake-3206")
    await before.chat(untitled.id)
    await run(before.db.close)

    const db = await reopen(filename, (sqlite) => {
      sqlite.exec(rewindWorkspaceNamesSql)
      sqlite
        .prepare(
          "insert into sessions (id, project_id, server_id, harness_id, title, origin, workspace_id, created_at, sidebar_state, sidebar_state_changed_at) select 'titled-chat', project_id, server_id, 'codex', 'Fix the login bug', 'codevisor', id, created_at, 'idle', created_at from workspaces where id = ?"
        )
        .run(titled.id)
    })

    expect(await nameOf(db, titled.id)).toBe("Fix the login bug")
    expect(await nameOf(db, untitled.id)).toBe("crispy-red-velvet-cake-3206")
  })

  it("are backfilled into drifted main chats, a hand-picked name winning", async () => {
    const filename = tempDatabase()
    const before = await openDatabase(filename)
    const renamed = await before.workspace("macro")
    const renamedChat = await before.chat(renamed.id, "had the orange soda drink for lunch")
    const automatic = await before.workspace("Fix the login bug")
    const automaticChat = await before.chat(automatic.id, "Fix the login bug")
    const fresh = await before.workspace("quesadilla-5480")
    const freshChat = await before.chat(fresh.id)
    await run(before.db.close)

    const db = await reopen(filename, (sqlite) => {
      sqlite.exec(rewindOneNameSql)
      sqlite.prepare(driftSql).run("macro", 1, renamed.id)
      sqlite.prepare(driftSql).run("Fix the signup bug", 0, automatic.id)
    })
    await run(db.updateSessionTitleFromHarness(renamedChat.id, "Logged lunch"))

    expect(await titleOf(db, renamedChat.id)).toBe("macro")
    expect(await titleOf(db, automaticChat.id)).toBe("Fix the signup bug")
    expect(await nameOf(db, fresh.id)).toBe("quesadilla-5480")
    expect(await titleOf(db, freshChat.id)).toBe("New Session")
  })
})

const driftSql = "update workspaces set name = ?, has_custom_name = ? where id = ?"

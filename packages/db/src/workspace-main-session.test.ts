import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { rewindMainSessionSql, run, tempDatabase } from "./test-support.js"

const openDatabase = async (filename = tempDatabase()) => {
  const db = await run(makeDatabase({ filename, serverId: "local" }))
  onTestFinished(() => run(db.close))
  const project = await run(db.createProject({ folderPath: "/tmp/main-session" }))
  const workspace = (name: string) =>
    run(db.upsertWorkspace({ projectId: project.id, name, hasCustomName: false }))
  const chat = (workspaceId?: string, origin?: "imported") =>
    run(
      db.createSession({
        projectId: project.id,
        harnessId: "codex",
        ...(workspaceId === undefined ? {} : { workspaceId }),
        ...(origin === undefined ? {} : { origin })
      })
    )
  return { db, project, workspace, chat }
}

const mainSessionOf = async (
  db: CodevisorDatabaseService,
  workspaceId: string
): Promise<string | undefined> =>
  (await run(db.listWorkspaces)).find((workspace) => workspace.id === workspaceId)?.mainSessionId

describe("workspace main session", () => {
  it("is the first chat to join a workspace, and stays put as side chats come and go", async () => {
    const { db, workspace, chat } = await openDatabase()
    const home = await workspace("Home")
    expect(await mainSessionOf(db, home.id)).toBeUndefined()

    const main = await chat(home.id)
    const side = await chat(home.id)
    const later = await chat()
    await run(db.setSessionWorkspace(later.id, home.id))
    await run(db.deleteSession(side.id))
    await run(db.setSessionWorkspace(later.id, null))

    expect(await mainSessionOf(db, home.id)).toBe(main.id)
  })

  it("comes back on a workspace created together with its first chat", async () => {
    const { db, project } = await openDatabase()

    const created = await run(
      db.createWorkspaceWithSession({
        workspace: { projectId: project.id, name: "Home", hasCustomName: false },
        session: { projectId: project.id, harnessId: "codex" }
      })
    )

    expect(created.workspace.mainSessionId).toBe(created.session.id)
  })

  it("passes to the oldest remaining chat when the main chat leaves", async () => {
    const { db, workspace, chat } = await openDatabase()
    const home = await workspace("Home")
    const elsewhere = await workspace("Elsewhere")
    const main = await chat(home.id)
    const imported = await chat(home.id, "imported")
    const side = await chat(home.id)

    await run(db.setSessionWorkspace(main.id, elsewhere.id))
    expect(await mainSessionOf(db, home.id)).toBe(side.id)
    expect(await mainSessionOf(db, elsewhere.id)).toBe(main.id)

    await run(db.deleteSession(side.id))
    expect(await mainSessionOf(db, home.id)).toBe(imported.id)

    await run(db.deleteSession(imported.id))
    expect(await mainSessionOf(db, home.id)).toBeUndefined()
  })

  it("is backfilled with each workspace's oldest Codevisor chat", async () => {
    const filename = tempDatabase()
    const before = await openDatabase(filename)
    const home = await before.workspace("Home")
    await before.chat(home.id, "imported")
    const main = await before.chat(home.id)
    await before.chat(home.id, "imported")
    const empty = await before.workspace("Empty")
    await run(before.db.close)
    const sqlite = new Database(filename)
    sqlite.exec(rewindMainSessionSql)
    sqlite.close()

    const db = await run(makeDatabase({ filename, serverId: "local" }))
    onTestFinished(() => run(db.close))

    expect(await mainSessionOf(db, home.id)).toBe(main.id)
    expect(await mainSessionOf(db, empty.id)).toBeUndefined()
  })
})

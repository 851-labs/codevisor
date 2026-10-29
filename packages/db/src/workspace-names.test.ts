import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { rewindWorkspaceNamesSql, run, tempDatabase } from "./test-support.js"

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
  const rename = (sessionId: string, title: string) => run(db.updateSession(sessionId, { title }))
  return { db, workspace, chat, rename }
}

const nameOf = async (db: CodevisorDatabaseService, workspaceId: string): Promise<string> =>
  (await run(db.listWorkspaces)).find((workspace) => workspace.id === workspaceId)?.name ?? ""

describe("workspace names", () => {
  it("follow the main chat's title once it has a real one", async () => {
    const { db, workspace, chat, rename } = await openDatabase()
    const home = await workspace("quesadilla-5480")
    const main = await chat(home.id)
    const side = await chat(home.id, "Side question")
    expect(await nameOf(db, home.id)).toBe("quesadilla-5480")

    await rename(main.id, "Fix the login bug")
    await rename(side.id, "Another side question")

    expect(await nameOf(db, home.id)).toBe("Fix the login bug")
  })

  it("take a titled chat's name as soon as it becomes the main chat", async () => {
    const { db, workspace, chat } = await openDatabase()
    const home = await workspace("quesadilla-5480")

    await chat(home.id, "Fix the login bug (fork)")

    expect(await nameOf(db, home.id)).toBe("Fix the login bug (fork)")
  })

  it("leave names someone chose by hand alone", async () => {
    const { db, workspace, chat, rename } = await openDatabase()
    const home = await workspace("My workspace", true)
    const main = await chat(home.id, "Fix the login bug")

    await rename(main.id, "Fix the signup bug")

    expect(await nameOf(db, home.id)).toBe("My workspace")
  })

  it("are backfilled from each workspace's main chat", async () => {
    const filename = tempDatabase()
    const before = await openDatabase(filename)
    const titled = await before.workspace("quesadilla-5480")
    const untitled = await before.workspace("crispy-red-velvet-cake-3206")
    await before.chat(untitled.id)
    await run(before.db.close)
    const sqlite = new Database(filename)
    sqlite.exec(rewindWorkspaceNamesSql)
    sqlite
      .prepare(
        "insert into sessions (id, project_id, server_id, harness_id, title, origin, workspace_id, created_at, sidebar_state, sidebar_state_changed_at) select 'titled-chat', project_id, server_id, 'codex', 'Fix the login bug', 'codevisor', id, created_at, 'idle', created_at from workspaces where id = ?"
      )
      .run(titled.id)
    sqlite.close()

    const db = await run(makeDatabase({ filename, serverId: "local" }))
    onTestFinished(() => run(db.close))

    expect(await nameOf(db, titled.id)).toBe("Fix the login bug")
    expect(await nameOf(db, untitled.id)).toBe("crispy-red-velvet-cake-3206")
  })
})

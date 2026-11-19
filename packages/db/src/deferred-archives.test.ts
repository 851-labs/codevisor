import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const openDatabase = async (): Promise<CodevisorDatabaseService> => {
  const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "machine-a" }))
  onTestFinished(() => run(db.close).catch(() => undefined))
  return db
}

const event = (db: CodevisorDatabaseService, sessionId: string, payload: object) =>
  run(db.appendEvent("session.updated", sessionId, payload))

const startTurn = (db: CodevisorDatabaseService, sessionId: string, turnId: string) =>
  event(db, sessionId, { initiatedBy: "user", turnId, turnState: "started" })

const endTurn = (
  db: CodevisorDatabaseService,
  sessionId: string,
  turnId: string,
  extra: object = {}
) => event(db, sessionId, { stopReason: "end_turn", turnId, turnState: "ended", ...extra })

const workspaceWithTwoChats = async (db: CodevisorDatabaseService) => {
  const project = await run(db.createProject({ folderPath: "/tmp/deferred-archives" }))
  const workspace = await run(
    db.upsertWorkspace({ projectId: project.id, name: "Work", hasCustomName: false })
  )
  const chat = () =>
    run(db.createSession({ projectId: project.id, harnessId: "codex", workspaceId: workspace.id }))
  return { workspace, main: await chat(), side: await chat() }
}

const dueSessionIds = async (db: CodevisorDatabaseService) =>
  (await run(db.listDueDeferredArchives)).map((archive) => archive.sessionId)

describe("deferred archives", () => {
  it("become due when the scheduling turn finishes, not when it pauses for an update", async () => {
    const db = await openDatabase()
    const { workspace, main } = await workspaceWithTwoChats(db)
    await startTurn(db, main.id, "turn-1")

    await run(
      db.scheduleDeferredArchive({
        sessionId: main.id,
        target: "workspace",
        workspaceId: workspace.id
      })
    )
    expect(await run(db.getDueDeferredArchive(main.id))).toBeUndefined()

    await endTurn(db, main.id, "turn-1", { stopKind: "pausedForUpdate" })
    expect(await dueSessionIds(db)).toEqual([])

    await startTurn(db, main.id, "turn-1")
    await endTurn(db, main.id, "turn-1")
    expect(await run(db.getDueDeferredArchive(main.id))).toEqual({
      sessionId: main.id,
      target: "workspace",
      workspaceId: workspace.id,
      scheduledAt: expect.any(String)
    })
  })

  it("is due at once when scheduled from a chat that is not in a turn", async () => {
    const db = await openDatabase()
    const { side } = await workspaceWithTwoChats(db)

    await run(db.scheduleDeferredArchive({ sessionId: side.id, target: "chat" }))

    expect(await dueSessionIds(db)).toEqual([side.id])
  })

  it("is cancelled by a message to any chat in its workspace, or to the chat it archives", async () => {
    const db = await openDatabase()
    const { workspace, main, side } = await workspaceWithTwoChats(db)
    const scheduleWorkspace = () =>
      run(
        db.scheduleDeferredArchive({
          sessionId: main.id,
          target: "workspace",
          workspaceId: workspace.id
        })
      )
    await scheduleWorkspace()
    await run(db.scheduleDeferredArchive({ sessionId: side.id, target: "chat" }))

    expect(await run(db.cancelDeferredArchivesFor(main.id))).toEqual([main.id])
    expect(await dueSessionIds(db)).toEqual([side.id])

    await scheduleWorkspace()
    expect(new Set(await run(db.cancelDeferredArchivesFor(side.id)))).toEqual(
      new Set([main.id, side.id])
    )
    expect(await dueSessionIds(db)).toEqual([])
  })

  it("is dropped when its chat or workspace is archived some other way first", async () => {
    const db = await openDatabase()
    const { workspace, main, side } = await workspaceWithTwoChats(db)
    await run(db.scheduleDeferredArchive({ sessionId: side.id, target: "chat" }))

    await run(db.archiveSession(side.id))
    expect(await dueSessionIds(db)).toEqual([])

    await run(
      db.scheduleDeferredArchive({
        sessionId: main.id,
        target: "workspace",
        workspaceId: workspace.id
      })
    )
    await run(db.updateWorkspace(workspace.id, { isArchived: true }))
    await run(db.updateWorkspace(workspace.id, { isArchived: false }))
    expect(await dueSessionIds(db)).toEqual([])
  })
})

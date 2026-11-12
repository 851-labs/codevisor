import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const openDatabase = async (filename = tempDatabase()) => {
  const db = await run(makeDatabase({ filename, serverId: "local" }))
  onTestFinished(() => run(db.close))
  return { db, filename }
}

const workspaceWithChat = async (db: CodevisorDatabaseService, projectId: string, name: string) =>
  run(
    db.createWorkspaceWithSession({
      workspace: { projectId, name, hasCustomName: true },
      session: { projectId, harnessId: "codex", title: `${name} chat` }
    })
  )

const sideChat = async (db: CodevisorDatabaseService, projectId: string, workspaceId: string) => {
  const chat = await run(db.createSession({ projectId, harnessId: "codex", workspaceId }))
  await run(db.setSessionWorkspace(chat.id, workspaceId))
  return chat
}

const archivedById = async (db: CodevisorDatabaseService) =>
  new Map((await run(db.listSessions)).map((chat) => [chat.id, chat.isArchived === true]))

describe("chat archived state", () => {
  it("archives and restores a workspace's chats with it", async () => {
    const { db } = await openDatabase()
    const project = await run(db.createProject({ folderPath: "/tmp/chat-archive" }))
    const shown = await workspaceWithChat(db, project.id, "shown")
    const side = await sideChat(db, project.id, shown.workspace.id)
    const other = await workspaceWithChat(db, project.id, "other")

    const archived = await run(db.updateWorkspace(shown.workspace.id, { isArchived: true }))

    const afterArchive = await run(db.listSessions)
    expect(afterArchive.find((chat) => chat.id === shown.session.id)).toMatchObject({
      isArchived: true,
      archivedAt: archived.archivedAt
    })
    expect((await archivedById(db)).get(side.id)).toBe(true)
    expect((await archivedById(db)).get(other.session.id)).toBe(false)

    await run(db.updateWorkspace(shown.workspace.id, { isArchived: false }))

    const restored = await run(db.getSessionSummary(shown.session.id))
    expect(restored.isArchived).toBeUndefined()
    expect(restored.archivedAt).toBeUndefined()
    expect((await archivedById(db)).get(side.id)).toBe(false)
  })

  it("leaves a chat alone when the workspace it moved out of is archived", async () => {
    const { db } = await openDatabase()
    const project = await run(db.createProject({ folderPath: "/tmp/chat-archive-moved" }))
    const parent = await workspaceWithChat(db, project.id, "parent")
    const wrapper = await workspaceWithChat(db, project.id, "wrapper")
    await run(db.setSessionWorkspace(wrapper.session.id, parent.workspace.id))

    await run(db.updateWorkspace(wrapper.workspace.id, { isArchived: true }))

    expect((await archivedById(db)).get(wrapper.session.id)).toBe(false)
  })

  it("stops an archived chat from counting as working or needing resume", async () => {
    const { db } = await openDatabase()
    const project = await run(db.createProject({ folderPath: "/tmp/chat-archive-working" }))
    const created = await workspaceWithChat(db, project.id, "working")
    await run(db.createPromptQueueItem(created.session.id, "later"))
    expect(await run(db.listSessionsRequiringResume)).toContain(created.session.id)

    await run(db.updateWorkspace(created.workspace.id, { isArchived: true }))

    expect(await run(db.listSessionsRequiringResume)).not.toContain(created.session.id)
  })

  it("backfills chats of workspaces archived before chats had their own state", async () => {
    const { db, filename } = await openDatabase()
    const project = await run(db.createProject({ folderPath: "/tmp/chat-archive-legacy" }))
    const retired = await workspaceWithChat(db, project.id, "retired")
    const live = await workspaceWithChat(db, project.id, "live")
    const archived = await run(db.updateWorkspace(retired.workspace.id, { isArchived: true }))
    await run(db.close)

    const sqlite = new Database(filename)
    try {
      sqlite.exec(rewindChatArchiveSql)
    } finally {
      sqlite.close()
    }

    const upgraded = await run(makeDatabase({ filename, serverId: "local" }))
    onTestFinished(() => run(upgraded.close))
    expect(await run(upgraded.getSessionSummary(retired.session.id))).toMatchObject({
      isArchived: true,
      archivedAt: archived.archivedAt
    })
    expect((await run(upgraded.getSessionSummary(live.session.id))).isArchived).toBeUndefined()

    await run(upgraded.updateWorkspace(retired.workspace.id, { isArchived: false }))
    expect((await run(upgraded.getSessionSummary(retired.session.id))).isArchived).toBeUndefined()
  })
})

const rewindChatArchiveSql = `
  drop trigger if exists navigation_sessions_update;
  drop index sessions_archived_idx;
  alter table sessions drop column archived_at;
  alter table sessions drop column is_archived;
  delete from schema_migrations where id = 100;
`

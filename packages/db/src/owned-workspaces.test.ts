import Database from "better-sqlite3"
import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const seed = async (filename: string) => {
  const db = await run(makeDatabase({ filename, serverId: "local" }))
  const project = await run(db.createProject({ folderPath: "/tmp/owned-workspaces" }))
  const create = (name: string, parentWorkspaceId?: string) =>
    run(
      db.upsertWorkspace({
        projectId: project.id,
        name,
        hasCustomName: false,
        ...(parentWorkspaceId === undefined ? {} : { parentWorkspaceId })
      })
    )
  const parent = await create("orchestrator")
  await run(
    db.upsertWorkspacePane(parent.id, {
      id: "00000000-0000-0000-0000-00000000000a",
      providerId: "codevisor",
      paneType: "terminal",
      title: "Chat"
    })
  )
  return { db, project, parent, create }
}

describe("@codevisor/db owned workspaces", () => {
  it("places a new child's tab group after the parent's tabs and keeps ownership across re-upserts", async () => {
    const { db, project, parent, create } = await seed(tempDatabase())
    const child = await create("worker", parent.id.toUpperCase())
    expect(child.parentWorkspaceId).toBe(parent.id)
    const chat = (await run(db.listWorkspacePanes)).find((p) => p.workspaceId === parent.id)
    expect(child.parentTabPosition! > chat!.position!).toBe(true)

    // A native client re-upserts the whole record without knowing the owner.
    const reupserted = await run(
      db.upsertWorkspace({
        id: child.id,
        projectId: project.id,
        name: "renamed",
        hasCustomName: true
      })
    )
    expect(reupserted.parentWorkspaceId).toBe(parent.id)
    expect(reupserted.parentTabPosition).toBe(child.parentTabPosition)

    // A tab opened later lands after the group.
    const later = await run(
      db.upsertWorkspacePane(parent.id, {
        id: "00000000-0000-0000-0000-00000000000b",
        providerId: "codevisor",
        paneType: "terminal",
        title: "Terminal"
      })
    )
    expect(later.position! > child.parentTabPosition!).toBe(true)
    await run(db.close)
  })

  it("promotes, re-parents, and rejects cycles and archived owners", async () => {
    const { db, parent, create } = await seed(tempDatabase())
    const child = await create("worker", parent.id)
    const grandchild = await create("helper", child.id)

    await expect(
      run(db.updateWorkspace(parent.id, { parentWorkspaceId: grandchild.id }))
    ).rejects.toThrow(/descendant/)
    await expect(
      run(db.updateWorkspace(child.id, { parentWorkspaceId: child.id }))
    ).rejects.toThrow(/descendant/)

    // Re-sending the current owner keeps the group where it is.
    expect(
      (await run(db.updateWorkspace(child.id, { parentWorkspaceId: parent.id }))).parentTabPosition
    ).toBe(child.parentTabPosition)
    await expect(
      run(db.updateWorkspace(child.id, { parentWorkspaceId: "missing-workspace" }))
    ).rejects.toThrow(/missing/)

    const promoted = await run(db.updateWorkspace(child.id, { parentWorkspaceId: null }))
    expect(promoted.parentWorkspaceId).toBeUndefined()
    expect(promoted.parentTabPosition).toBeUndefined()

    const archived = await create("archived")
    await run(db.updateWorkspace(archived.id, { isArchived: true }))
    await expect(
      run(db.updateWorkspace(child.id, { parentWorkspaceId: archived.id }))
    ).rejects.toThrow(/archived/)
    await run(db.close)
  })

  it("stores group collapse and folder filing", async () => {
    const { db, parent, create } = await seed(tempDatabase())
    const child = await create("worker", parent.id)
    const folder = "0000000F-0000-0000-0000-000000000001"
    expect(await run(db.updateWorkspace(child.id, { groupCollapsed: true }))).toMatchObject({
      groupCollapsed: true
    })
    const filed = await run(db.updateWorkspace(parent.id, { folderId: folder }))
    expect(filed.folderId).toBe(folder.toLowerCase())
    // Unrelated writes keep both.
    expect(await run(db.updateWorkspace(parent.id, { name: "renamed" }))).toMatchObject({
      folderId: folder.toLowerCase()
    })
    expect((await run(db.updateWorkspace(parent.id, { folderId: null }))).folderId).toBeUndefined()
    await run(db.close)
  })

  it("reorders tabs and owned tab groups as one strip", async () => {
    const { db, parent, create } = await seed(tempDatabase())
    const chatId = "00000000-0000-0000-0000-00000000000a"
    const first = await create("first", parent.id)
    const second = await create("second", parent.id)
    await run(db.reorderWorkspacePanes(parent.id, [second.id, chatId, first.id]))

    const workspaces = await run(db.listWorkspaces)
    const panes = await run(db.listWorkspacePanes)
    const positions = new Map<string, string>([
      ...workspaces.map((w) => [w.id, w.parentTabPosition ?? ""] as const),
      ...panes.map((p) => [p.id, p.position ?? ""] as const)
    ])
    const order = [second.id, chatId, first.id].toSorted((a, b) =>
      positions.get(a)! < positions.get(b)! ? -1 : 1
    )
    expect(order).toEqual([second.id, chatId, first.id])
    await run(db.close)
  })

  it("journals a chat's parent and labels so clients learn them", async () => {
    const filename = tempDatabase()
    const { db, project } = await seed(filename)
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    const changes = () =>
      (
        new Database(filename)
          .prepare(
            "select count(*) as count from events where kind = 'navigation.changed' and subject_id = ?"
          )
          .get(session.id) as { count: number }
      ).count
    const before = changes()
    await run(db.updateSession(session.id, { labels: { role: "worker" } }))
    expect(changes()).toBe(before + 1)
    await run(db.close)
  })
})

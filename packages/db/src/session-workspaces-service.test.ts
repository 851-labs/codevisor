import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { DatabaseError, makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("session workspaces service", () => {
  it("removes a detached session pane when another pane keeps the workspace nonempty", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/detached-session-pane" }))
    const workspace = await run(
      db.upsertWorkspace({ projectId: project.id, name: "Main", hasCustomName: false })
    )
    const first = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    const second = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    await run(db.setSessionWorkspace(first.id, workspace.id))
    await run(db.setSessionWorkspace(second.id, workspace.id))

    await run(db.setSessionWorkspace(first.id, null))

    expect(await run(db.listWorkspacePanes)).toEqual([
      expect.objectContaining({ resourceId: second.id })
    ])
    const target = await run(
      db.upsertWorkspace({ projectId: project.id, name: "Target", hasCustomName: false })
    )
    await run(db.setSessionWorkspace(second.id, target.id))
    await run(db.setSessionWorkspace(second.id, target.id))
    const third = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    await run(db.setSessionWorkspace(third.id, workspace.id))
    await run(db.setSessionWorkspace(third.id, target.id))
    expect(await run(db.listWorkspacePanes)).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ workspaceId: workspace.id, paneType: "new-tab" }),
        expect.objectContaining({ workspaceId: target.id, resourceId: second.id })
      ])
    )
    await run(db.close)
  })

  it("binds sessions to pane workspaces at creation and afterwards", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/workspace-sessions" }))
    const workspace = await run(
      db.upsertWorkspace({
        id: "workspace-1",
        projectId: project.id,
        name: "Main",
        hasCustomName: false
      })
    )

    const attached = await run(
      db.createSession({ projectId: project.id, harnessId: "codex", workspaceId: workspace.id })
    )
    expect(attached.workspaceId).toBe(workspace.id)
    expect(
      (await run(db.listSessions)).find((session) => session.id === attached.id)?.workspaceId
    ).toBe(workspace.id)

    const detached = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    expect(detached.workspaceId).toBeUndefined()

    await run(db.setSessionWorkspace(detached.id, workspace.id))
    expect((await run(db.getSessionSummary(detached.id))).workspaceId).toBe(workspace.id)
    await run(db.setSessionWorkspace(detached.id, null))
    expect((await run(db.getSessionSummary(detached.id))).workspaceId).toBeUndefined()
    expect(await run(db.listWorkspacePanes)).toEqual([
      expect.objectContaining({ id: detached.id, paneType: "new-tab" })
    ])
    expect((await run(db.listWorkspacePanes))[0]?.resourceId).toBeUndefined()
    await run(db.setSessionWorkspace(attached.id, null))
    expect(await run(db.listWorkspacePanes)).toEqual([
      expect.objectContaining({ id: detached.id, paneType: "new-tab" })
    ])

    const deletionWorkspace = await run(
      db.upsertWorkspace({ projectId: project.id, name: "Delete", hasCustomName: false })
    )
    const deletedSession = await run(
      db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    await run(db.setSessionWorkspace(deletedSession.id, deletionWorkspace.id))
    await run(db.deleteSession(deletedSession.id))
    expect(
      (await run(db.listWorkspacePanes)).find((pane) => pane.workspaceId === deletionWorkspace.id)
    ).toMatchObject({ id: deletedSession.id, paneType: "new-tab", revision: 2 })

    await expect(run(db.setSessionWorkspace("missing", workspace.id))).rejects.toBeInstanceOf(
      DatabaseError
    )
    // A session cannot point at a workspace that does not exist.
    await expect(
      run(db.setSessionWorkspace(detached.id, "missing-workspace"))
    ).rejects.toBeInstanceOf(DatabaseError)
    await Effect.runPromise(db.close)
  })
})

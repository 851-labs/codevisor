import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { DatabaseError, makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
  it("cascades workspace archive to its sessions without touching siblings", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/ws-cascade" }))
    const workspace = await run(
      db.upsertWorkspace({ projectId: project.id, name: "feature", hasCustomName: false })
    )
    const inside = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    const outside = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    await run(db.setSessionWorkspace(inside.id, workspace.id))

    await run(db.updateWorkspace(workspace.id, { isArchived: true }))
    expect((await run(db.getSessionSummary(inside.id))).isArchived).toBe(true)
    expect((await run(db.getSessionSummary(outside.id))).isArchived).toBe(false)

    await run(db.updateWorkspace(workspace.id, { isArchived: false }))
    expect((await run(db.getSessionSummary(inside.id))).isArchived).toBe(false)
    await run(db.close)
  })

  it("cascades through a full workspace upsert, not just a patch", async () => {
    // The macOS client writes workspaces with PUT, so the upsert path owes
    // the same cascade a PATCH does — otherwise archiving from that client
    // would hide the workspace while leaving its chats in the sidebar.
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/ws-upsert-cascade" }))
    const workspace = await run(
      db.upsertWorkspace({ projectId: project.id, name: "feature", hasCustomName: false })
    )
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    await run(db.setSessionWorkspace(session.id, workspace.id))

    await run(
      db.upsertWorkspace({
        id: workspace.id,
        projectId: project.id,
        name: "feature",
        hasCustomName: false,
        isArchived: true
      })
    )
    expect((await run(db.getSessionSummary(session.id))).isArchived).toBe(true)

    await run(
      db.upsertWorkspace({
        id: workspace.id,
        projectId: project.id,
        name: "feature",
        hasCustomName: false,
        isArchived: false
      })
    )
    expect((await run(db.getSessionSummary(session.id))).isArchived).toBe(false)
    await run(db.close)
  })

  it("preserves untouched workspace fields and the original archived moment", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/ws-partial" }))
    const workspace = await run(
      db.upsertWorkspace({ projectId: project.id, name: "pinned", hasCustomName: true })
    )
    await run(db.updateWorkspace(workspace.id, { isArchived: true }))
    const firstStamp = (await run(db.listWorkspaces)).find(
      (candidate) => candidate.id === workspace.id
    )?.archivedAt

    // A rename that says nothing about naming or archiving must not silently
    // clear the custom-name pin or re-stamp the archive moment.
    const renamed = await run(db.updateWorkspace(workspace.id, { name: "still pinned" }))

    expect(renamed.name).toBe("still pinned")
    expect(renamed.hasCustomName).toBe(true)
    expect(renamed.isArchived).toBe(true)
    expect(renamed.archivedAt).toBe(firstStamp)
    await run(db.close)
  })

  it("re-archiving an already archived workspace does not cascade again", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/ws-rearchive" }))
    const workspace = await run(
      db.upsertWorkspace({ projectId: project.id, name: "feature", hasCustomName: false })
    )
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    await run(db.setSessionWorkspace(session.id, workspace.id))
    await run(db.updateWorkspace(workspace.id, { isArchived: true }))

    // Restore the chat by hand, then re-archive the already-archived
    // workspace: the no-op transition must not drag the chat back down.
    await run(db.updateSession(session.id, { isArchived: false }))
    await run(db.updateWorkspace(workspace.id, { isArchived: true }))

    expect((await run(db.getSessionSummary(session.id))).isArchived).toBe(false)
    await run(db.close)
  })

  it("rejects updating a workspace that does not exist", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    await expect(
      run(db.updateWorkspace("6f1d5f9e-1c2b-4a3d-8e5f-0a1b2c3d4e5f", { isArchived: true }))
    ).rejects.toThrow(/Workspace not found/)
    await run(db.close)
  })

  it("persists, lists, updates, and deletes pane workspaces", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "machine-a" }))
    const project = await run(db.createProject({ folderPath: "/tmp/pane-workspaces" }))

    const created = await run(
      db.upsertWorkspace({
        id: "workspace-1",
        projectId: project.id,
        name: "Main",
        hasCustomName: false,
        createdAt: "2026-07-01T00:00:00.000Z"
      })
    )
    expect(created).toEqual({
      id: "workspace-1",
      serverId: "machine-a",
      projectId: project.id,
      name: "Main",
      hasCustomName: false,
      isArchived: false,
      createdAt: "2026-07-01T00:00:00.000Z"
    })

    // Omitted ids and creation dates are generated server-side.
    const generated = await run(
      db.upsertWorkspace({ projectId: project.id, name: "Scratch", hasCustomName: false })
    )
    expect(generated.id).toMatch(/^[0-9a-f-]{36}$/)
    expect(Date.parse(generated.createdAt)).not.toBeNaN()

    // Re-upserting the same id updates in place, stamps updated_at, and keeps
    // the original creation date.
    const updated = await run(
      db.upsertWorkspace({
        id: "workspace-1",
        projectId: project.id,
        name: "Renamed",
        hasCustomName: true,
        symbolName: "hammer",
        rootDirectory: "/tmp/pane-workspaces/worktree",
        isArchived: true,
        createdAt: "2026-07-02T00:00:00.000Z"
      })
    )
    expect(updated).toMatchObject({
      id: "workspace-1",
      name: "Renamed",
      hasCustomName: true,
      symbolName: "hammer",
      rootDirectory: "/tmp/pane-workspaces/worktree",
      isArchived: true,
      createdAt: "2026-07-01T00:00:00.000Z"
    })
    expect(updated.updatedAt).toBeDefined()
    expect(created.updatedAt).toBeUndefined()

    // Newest first.
    expect((await run(db.listWorkspaces)).map((workspace) => workspace.id)).toEqual([
      generated.id,
      "workspace-1"
    ])

    // A workspace cannot exist without its project.
    await expect(
      run(db.upsertWorkspace({ projectId: "missing", name: "Nope", hasCustomName: false }))
    ).rejects.toBeInstanceOf(DatabaseError)

    await run(db.deleteWorkspace(generated.id))
    expect((await run(db.listWorkspaces)).map((workspace) => workspace.id)).toEqual(["workspace-1"])
    await expect(run(db.deleteWorkspace("missing"))).rejects.toBeInstanceOf(DatabaseError)

    // Deleting a project cascades its workspaces (and their sessions) away.
    const session = await run(
      db.createSession({ projectId: project.id, harnessId: "codex", workspaceId: "workspace-1" })
    )
    await run(db.deleteProject(project.id))
    expect(await run(db.listWorkspaces)).toEqual([])
    await expect(run(db.getSessionSummary(session.id))).rejects.toBeInstanceOf(DatabaseError)
    await Effect.runPromise(db.close)
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

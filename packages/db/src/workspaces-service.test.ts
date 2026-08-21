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
        rootDirectory: "/tmp/pane-workspaces/worktree",
        isArchived: true,
        createdAt: "2026-07-02T00:00:00.000Z"
      })
    )
    expect(updated).toMatchObject({
      id: "workspace-1",
      name: "Renamed",
      hasCustomName: true,
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

  it("owns pane identity while session assignment supplies legacy chat panes", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "machine-a" }))
    const project = await run(db.createProject({ folderPath: "/tmp/workspace-pane-registry" }))
    const first = await run(
      db.upsertWorkspace({ projectId: project.id, name: "First", hasCustomName: false })
    )
    const second = await run(
      db.upsertWorkspace({ projectId: project.id, name: "Second", hasCustomName: false })
    )
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    await run(db.setSessionWorkspace(session.id, first.id))
    expect(await run(db.listWorkspacePanes)).toEqual([
      expect.objectContaining({
        id: session.id,
        workspaceId: first.id,
        providerId: "codevisor",
        paneType: "chat",
        resourceKind: "session",
        resourceId: session.id
      })
    ])

    const placeholder = await run(
      db.upsertWorkspacePane(first.id, {
        id: "pane-placeholder",
        providerId: "codevisor",
        paneType: "new-tab",
        title: "New tab"
      })
    )
    expect(placeholder).toMatchObject({ id: "pane-placeholder", workspaceId: first.id })

    // Conversion preserves the placeholder id and replaces the compatibility
    // pane that session membership had synthesized.
    const converted = await run(
      db.upsertWorkspacePane(first.id, {
        id: placeholder.id,
        providerId: "codevisor",
        paneType: "chat",
        title: "Chat",
        resourceKind: "session",
        resourceId: session.id
      })
    )
    expect(converted.id).toBe("pane-placeholder")
    expect(
      (await run(db.listWorkspacePanes)).filter((pane) => pane.resourceId === session.id)
    ).toHaveLength(1)

    await run(db.setSessionWorkspace(session.id, second.id))
    expect(
      (await run(db.listWorkspacePanes)).find((pane) => pane.id === "pane-placeholder")
    ).toMatchObject({ workspaceId: second.id })
    expect(
      (await run(db.listWorkspacePanes)).filter((pane) => pane.workspaceId === first.id)
    ).toEqual([expect.objectContaining({ paneType: "new-tab" })])

    const finalReplacement = await run(db.deleteWorkspacePane(second.id, "pane-placeholder"))
    expect(finalReplacement).toMatchObject({
      id: "pane-placeholder",
      workspaceId: second.id,
      paneType: "new-tab",
      revision: 4
    })
    await run(db.setSessionWorkspace(session.id, second.id))
    expect(
      (await run(db.listWorkspacePanes)).filter((pane) => pane.workspaceId === second.id)
    ).toHaveLength(2)
    await run(db.deleteSession(session.id))
    expect(
      (await run(db.listWorkspacePanes)).filter((pane) => pane.workspaceId === second.id)
    ).toEqual([expect.objectContaining({ id: "pane-placeholder", paneType: "new-tab" })])
    await run(db.close)
  })

  it("promotes a placeholder and assigns its chat in one pane mutation", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "machine-a" }))
    const project = await run(db.createProject({ folderPath: "/tmp/atomic-pane-promotion" }))
    const workspace = await run(
      db.upsertWorkspace({ projectId: project.id, name: "Main", hasCustomName: false })
    )
    const session = await run(
      db.createSession({ projectId: project.id, harnessId: "codex", title: "New Chat" })
    )
    const placeholder = await run(
      db.upsertWorkspacePane(workspace.id, {
        id: "stable-pane",
        providerId: "codevisor",
        paneType: "new-tab",
        title: "New tab"
      })
    )
    expect(placeholder.revision).toBe(1)

    const promoted = await run(
      db.promoteWorkspacePaneToSession(workspace.id, placeholder.id, session.id, "New Chat")
    )

    expect(promoted).toMatchObject({
      id: placeholder.id,
      paneType: "chat",
      resourceKind: "session",
      resourceId: session.id,
      revision: 2
    })
    expect(await run(db.listWorkspacePanes)).toEqual([promoted])
    expect((await run(db.getSessionSummary(session.id))).workspaceId).toBe(workspace.id)
    await run(db.close)
  })

  it("validates and revision-orders every pane mutation shape", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "machine-a" }))
    const project = await run(db.createProject({ folderPath: "/tmp/pane-mutation-shapes" }))
    const otherProject = await run(db.createProject({ folderPath: "/tmp/other-pane-project" }))
    const first = await run(
      db.upsertWorkspace({ projectId: project.id, name: "First", hasCustomName: false })
    )
    const second = await run(
      db.upsertWorkspace({ projectId: project.id, name: "Second", hasCustomName: false })
    )
    const generated = await run(
      db.upsertWorkspacePane(first.id, {
        providerId: "extension.test",
        paneType: "custom",
        title: "Generated",
        metadata: JSON.stringify({ value: 1 }),
        createdAt: "2026-08-17T00:00:00.000Z"
      })
    )
    expect(generated.metadata).toBe('{"value":1}')

    await expect(
      run(
        db.upsertWorkspacePane(second.id, {
          id: generated.id,
          providerId: "extension.test",
          paneType: "custom",
          title: "Wrong workspace"
        })
      )
    ).rejects.toThrow(/belongs to workspace/)
    await expect(
      run(
        db.upsertWorkspacePane(first.id, {
          providerId: "extension.test",
          paneType: "custom",
          title: "Partial resource",
          resourceKind: "terminal"
        })
      )
    ).rejects.toThrow(/must be provided together/)
    await expect(run(db.updateWorkspacePane(first.id, "missing", {}))).rejects.toThrow(
      /Workspace pane not found/
    )

    const terminal = await run(
      db.updateWorkspacePane(first.id, generated.id, {
        providerId: "codevisor",
        paneType: "terminal",
        title: "Shell",
        resourceKind: "terminal",
        resourceId: "terminal-key",
        metadata: JSON.stringify({ attachOnly: true })
      })
    )
    expect(terminal).toMatchObject({
      providerId: "codevisor",
      paneType: "terminal",
      resourceKind: "terminal",
      resourceId: "terminal-key",
      revision: 2
    })
    expect((await run(db.updateWorkspacePane(first.id, generated.id, {}))).revision).toBe(3)
    await expect(
      run(db.updateWorkspacePane(first.id, generated.id, { resourceKind: null }))
    ).rejects.toThrow(/must be provided together/)
    await expect(
      run(db.updateWorkspacePane(first.id, generated.id, { resourceId: null }))
    ).rejects.toThrow(/must be provided together/)
    const cleared = await run(
      db.updateWorkspacePane(first.id, generated.id, {
        resourceKind: null,
        resourceId: null,
        metadata: null
      })
    )
    expect(cleared).toMatchObject({ revision: 4 })
    expect(cleared.resourceKind).toBeUndefined()
    expect(cleared.metadata).toBeUndefined()

    const session = await run(
      db.createSession({ projectId: project.id, harnessId: "codex", title: "Chat" })
    )
    const assigned = await run(
      db.updateWorkspacePane(first.id, generated.id, {
        paneType: "chat",
        resourceKind: "session",
        resourceId: session.id
      })
    )
    expect(assigned.revision).toBe(5)
    expect((await run(db.getSessionSummary(session.id))).workspaceId).toBe(first.id)

    await expect(
      run(db.promoteWorkspacePaneToSession(first.id, "missing", session.id, "Chat"))
    ).rejects.toThrow(/Workspace pane not found/)
    await expect(
      run(db.promoteWorkspacePaneToSession(first.id, generated.id, "missing", "Chat"))
    ).rejects.toThrow(/Session not found/)
    const otherSession = await run(
      db.createSession({ projectId: otherProject.id, harnessId: "codex", title: "Other" })
    )
    await expect(
      run(db.promoteWorkspacePaneToSession(first.id, generated.id, otherSession.id, "Other"))
    ).rejects.toThrow(/different projects/)

    const closed = await run(db.deleteWorkspacePane(first.id, generated.id))
    expect(closed).toMatchObject({ id: generated.id, paneType: "new-tab", revision: 6 })
    // Retrying the same final-pane close is idempotent: same identity and no
    // additional revision.
    expect(await run(db.deleteWorkspacePane(first.id, generated.id))).toEqual(closed)

    const emptyTitle = await run(
      db.createSession({ projectId: project.id, harnessId: "codex", title: "" })
    )
    await run(db.setSessionWorkspace(emptyTitle.id, second.id))
    expect(
      (await run(db.listWorkspacePanes)).find((pane) => pane.resourceId === emptyTitle.id)?.title
    ).toBe("Chat")
    await run(db.close)
  })

  it("serializes competing closes and preserves exactly one final pane", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "machine-a" }))
    const project = await run(db.createProject({ folderPath: "/tmp/atomic-pane-close" }))
    const workspace = await run(
      db.upsertWorkspace({ projectId: project.id, name: "Main", hasCustomName: false })
    )
    await run(
      db.upsertWorkspacePane(workspace.id, {
        id: "first-pane",
        providerId: "codevisor",
        paneType: "terminal",
        title: "One",
        resourceKind: "terminal",
        resourceId: "one"
      })
    )
    await run(
      db.upsertWorkspacePane(workspace.id, {
        id: "second-pane",
        providerId: "codevisor",
        paneType: "terminal",
        title: "Two",
        resourceKind: "terminal",
        resourceId: "two"
      })
    )

    expect(await run(db.deleteWorkspacePane(workspace.id, "first-pane"))).toBeUndefined()
    const survivor = await run(db.deleteWorkspacePane(workspace.id, "second-pane"))
    expect(survivor).toMatchObject({
      id: "second-pane",
      paneType: "new-tab",
      title: "New tab",
      revision: 2
    })
    expect(await run(db.deleteWorkspacePane(workspace.id, "first-pane"))).toBeUndefined()
    expect(await run(db.deleteWorkspacePane(workspace.id, "second-pane"))).toEqual(survivor)
    expect(await run(db.listWorkspacePanes)).toEqual([survivor])

    const snapshot = await run(db.getWorkspaceSnapshot)
    expect(snapshot.workspaces.map((item) => item.id)).toContain(workspace.id)
    expect(snapshot.panes).toEqual([survivor])
    await run(db.close)
  })
})

import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("workspace creation service", () => {
  it("creates a workspace around its first chat as one journal change", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "machine-a" }))
    const project = await run(db.createProject({ folderPath: "/tmp/atomic-workspace-create" }))
    const before = await run(db.latestEventCursor)
    const request = {
      workspace: {
        id: "ws-atomic",
        projectId: project.id,
        name: "Main",
        hasCustomName: false,
        rootDirectory: "/tmp/atomic-workspace-create"
      },
      session: { id: "chat-atomic", projectId: project.id, harnessId: "codex", title: "Hello" }
    }

    const created = await run(db.createWorkspaceWithSession(request))

    expect(created.workspace).toMatchObject({ id: "ws-atomic", projectId: project.id })
    expect(created.session).toMatchObject({ id: "chat-atomic", workspaceId: "ws-atomic" })
    expect(created.pane).toMatchObject({
      id: "chat-atomic",
      workspaceId: "ws-atomic",
      paneType: "chat",
      resourceKind: "session",
      resourceId: "chat-atomic",
      title: "Hello",
      revision: 1
    })
    // The journal coalesces the three rows into ONE delta: no client can
    // observe the workspace without its chat.
    const batch = await run(db.readSyncBatch(before))
    const deltas = batch.events.filter((event) => event.kind === "navigation.changed")
    expect(deltas).toHaveLength(1)
    expect(deltas[0]?.payload).toMatchObject({
      workspaces: [expect.objectContaining({ id: "ws-atomic" })],
      sessions: [expect.objectContaining({ id: "chat-atomic", workspaceId: "ws-atomic" })],
      panes: [expect.objectContaining({ id: "chat-atomic" })]
    })

    // A retried request converges on the same records.
    const retried = await run(db.createWorkspaceWithSession(request))
    expect(retried.session.id).toBe("chat-atomic")
    expect(await run(db.listWorkspacePanes)).toEqual([
      expect.objectContaining({ id: "chat-atomic", revision: 2 })
    ])

    // A cross-project pair is rejected and the transaction rolls back whole.
    const other = await run(db.createProject({ folderPath: "/tmp/atomic-workspace-other" }))
    await expect(
      run(
        db.createWorkspaceWithSession({
          workspace: { id: "ws-other", projectId: other.id, name: "Other", hasCustomName: false },
          session: { id: "chat-atomic", projectId: project.id, harnessId: "codex" }
        })
      )
    ).rejects.toThrow(/different projects/)
    expect((await run(db.listWorkspaces)).map((workspace) => workspace.id)).not.toContain(
      "ws-other"
    )
    await run(db.close)
  })

  it("keeps an existing workspace's metadata and honors pane and title options", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "machine-a" }))
    const project = await run(db.createProject({ folderPath: "/tmp/atomic-workspace-existing" }))
    const existing = await run(
      db.upsertWorkspace({
        id: "ws-existing",
        projectId: project.id,
        name: "Kept",
        hasCustomName: true
      })
    )

    const created = await run(
      db.createWorkspaceWithSession({
        workspace: {
          id: existing.id,
          projectId: project.id,
          name: "Ignored",
          hasCustomName: false
        },
        session: { id: "chat-titled", projectId: project.id, harnessId: "codex", title: "" },
        pane: { id: "pane-explicit", title: "Custom" }
      })
    )
    expect(created.workspace).toMatchObject({
      id: "ws-existing",
      name: "Kept",
      hasCustomName: true
    })
    expect(created.pane).toMatchObject({ id: "pane-explicit", title: "Custom" })

    // No pane options: the pane takes the session id and a "Chat" title for an
    // untitled session. No workspace id: the server mints one.
    const untitled = await run(
      db.createWorkspaceWithSession({
        workspace: { projectId: project.id, name: "Minted", hasCustomName: false },
        session: { projectId: project.id, harnessId: "codex", title: "" }
      })
    )
    expect(untitled.pane).toMatchObject({ id: untitled.session.id, title: "Chat" })
    expect(untitled.workspace.id).toMatch(/^[0-9a-f-]{36}$/)
    expect(untitled.session.workspaceId).toBe(untitled.workspace.id)
    await run(db.close)
  })
})

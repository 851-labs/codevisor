import { describe, expect, it } from "vitest"
import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("workspace pane conflicts", () => {
  it("preserves the final source pane when a resource moves through an explicit pane", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "machine-a" }))
    const project = await run(db.createProject({ folderPath: "/tmp/workspace-pane-conflicts" }))
    const source = await run(
      db.upsertWorkspace({ projectId: project.id, name: "Source", hasCustomName: false })
    )
    const target = await run(
      db.upsertWorkspace({ projectId: project.id, name: "Target", hasCustomName: false })
    )
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    await run(db.setSessionWorkspace(session.id, source.id))

    const moved = await run(
      db.upsertWorkspacePane(target.id, {
        id: "explicit-pane",
        providerId: "codevisor",
        paneType: "chat",
        title: "Moved chat",
        resourceKind: "session",
        resourceId: session.id
      })
    )

    expect(moved).toMatchObject({ workspaceId: target.id, resourceId: session.id })
    const panes = await run(db.listWorkspacePanes)
    expect(panes).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: session.id,
          workspaceId: source.id,
          paneType: "new-tab"
        }),
        expect.objectContaining({ id: "explicit-pane", workspaceId: target.id })
      ])
    )
    expect(panes.find((pane) => pane.id === session.id)?.resourceId).toBeUndefined()
    await expect(run(db.deleteWorkspacePane("missing", "missing"))).rejects.toThrow(
      /Workspace not found/
    )
    await run(db.close)
  })
})

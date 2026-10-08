import type { UpdateWorkspacePaneRequest, UpsertWorkspacePaneRequest } from "@codevisor/api"
import { describe, expect, it, vi } from "vitest"

import { memoryDatabase, run } from "./test-support.js"

describe("workspace pane lifecycle", () => {
  it("reads pane requests and database state when the public Effect executes", async () => {
    const { db, project } = await memoryDatabase()
    const request = {
      id: "deferred-pane",
      providerId: "codevisor",
      paneType: "chat",
      title: "Before",
      createdAt: undefined as string | undefined
    } satisfies UpsertWorkspacePaneRequest
    const pending = db.upsertWorkspacePane("deferred-workspace", request)
    const patch = { title: "Before patch" } satisfies UpdateWorkspacePaneRequest
    const pendingPatch = db.updateWorkspacePane("deferred-workspace", "deferred-pane", patch)
    const pendingDelete = db.deleteWorkspacePane("deferred-workspace", "deferred-pane")
    expect(await run(db.listWorkspacePanes)).toEqual([])
    await run(
      db.upsertWorkspace({
        id: "deferred-workspace",
        projectId: project.id,
        name: "Deferred",
        hasCustomName: false
      })
    )
    request.title = "At execution"
    request.createdAt = "2026-07-01T00:00:00.000Z"
    expect(await run(pending)).toEqual({
      id: "deferred-pane",
      workspaceId: "deferred-workspace",
      providerId: "codevisor",
      paneType: "chat",
      title: "At execution",
      revision: 1,
      createdAt: "2026-07-01T00:00:00.000Z",
      position: expect.stringMatching(/^[0-9a-f]+$/)
    })
    patch.title = "Patch at execution"
    expect(await run(pendingPatch)).toMatchObject({ title: "Patch at execution", revision: 2 })
    await run(pendingDelete)
    expect(await run(db.listWorkspacePanes)).toEqual([])
  })

  it("keeps revision and update time on an identical explicit upsert", async () => {
    const { db, project } = await memoryDatabase()
    const workspace = await run(
      db.upsertWorkspace({
        projectId: project.id,
        name: "Main",
        hasCustomName: false
      })
    )
    vi.useFakeTimers({ toFake: ["Date"] })
    try {
      vi.setSystemTime(new Date("2026-07-01T00:00:00.000Z"))
      const request = { id: "retry-pane", providerId: "codevisor", paneType: "chat", title: "One" }
      await run(db.upsertWorkspacePane(workspace.id, request))
      request.title = "Two"
      const changed = await run(db.upsertWorkspacePane(workspace.id, request))
      expect(changed).toEqual({
        id: "retry-pane",
        workspaceId: workspace.id,
        providerId: "codevisor",
        paneType: "chat",
        title: "Two",
        revision: 2,
        position: expect.stringMatching(/^[0-9a-f]+$/),
        createdAt: "2026-07-01T00:00:00.000Z",
        updatedAt: "2026-07-01T00:00:00.000Z"
      })
      vi.setSystemTime(new Date("2026-07-02T00:00:00.000Z"))
      expect(await run(db.upsertWorkspacePane(workspace.id, request))).toEqual({
        id: "retry-pane",
        workspaceId: workspace.id,
        providerId: "codevisor",
        paneType: "chat",
        title: "Two",
        revision: 2,
        position: expect.stringMatching(/^[0-9a-f]+$/),
        createdAt: "2026-07-01T00:00:00.000Z",
        updatedAt: "2026-07-01T00:00:00.000Z"
      })
    } finally {
      vi.useRealTimers()
    }
  })
})

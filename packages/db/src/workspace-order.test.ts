import { initialWorkspacePosition, workspacePositionEpoch } from "@codevisor/api"
import { afterEach, describe, expect, it, vi } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

afterEach(() => vi.useRealTimers())

describe("shared workspace positions", () => {
  it("assigns one initial position and puts consecutive creations on top with a frozen clock", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(new Date("2026-09-14T12:00:00Z"))
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/workspace-order" }))
      const request = { projectId: project.id, name: "Workspace", hasCustomName: false }
      const first = await run(db.upsertWorkspace(request))
      const second = await run(db.upsertWorkspace(request))
      expect(second.sidebarPosition! < first.sidebarPosition!).toBe(true)
      const reobserved = await run(
        db.upsertWorkspace({ ...request, id: first.id, sidebarOrderHead: second.sidebarPosition! })
      )
      expect(reobserved.sidebarPosition).toBe(first.sidebarPosition)
      expect(reobserved.sidebarOrderRevision).toBe(1)
      expect((await run(db.listWorkspaces)).map((row) => row.id)).toEqual([second.id, first.id])
    } finally {
      await run(db.close)
    }
  })

  it("creates above another machine's observed frontier even when this machine's clock is behind", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(new Date("2026-09-14T12:00:00Z"))
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/workspace-frontier" }))
      const head = initialWorkspacePosition(
        Date.now() + 60_000,
        "00000000-0000-0000-0000-000000000001"
      )
      const workspace = await run(
        db.upsertWorkspace({
          projectId: project.id,
          name: "New",
          hasCustomName: false,
          sidebarOrderHead: head
        })
      )
      expect(workspace.sidebarPosition! < head).toBe(true)
      expect(workspacePositionEpoch(workspace.sidebarPosition!)).toBe(
        workspacePositionEpoch(head) + 1
      )
    } finally {
      await run(db.close)
    }
  })

  it("applies the latest move even from a stale revision, and keeps order through metadata changes", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/workspace-order-lww" }))
      const request = { projectId: project.id, name: "Workspace", hasCustomName: false }
      const first = await run(db.upsertWorkspace(request))
      const sibling = await run(db.upsertWorkspace(request))
      const earlier = initialWorkspacePosition(100, first.id)
      await run(
        db.updateWorkspace(first.id, { sidebarOrder: { position: earlier, expectedRevision: 1 } })
      )
      // A second move of the same drag, sent before its sender saw the first
      // one land, still carries the first revision.
      const latest = initialWorkspacePosition(50, first.id)
      const moved = await run(
        db.updateWorkspace(first.id, { sidebarOrder: { position: latest, expectedRevision: 1 } })
      )
      expect(moved.sidebarPosition).toBe(latest)
      expect(moved.sidebarOrderRevision).toBe(3)
      const unrevisioned = await run(
        db.updateWorkspace(first.id, { sidebarOrder: { position: earlier } })
      )
      expect(unrevisioned.sidebarPosition).toBe(earlier)
      await run(db.updateWorkspace(first.id, { name: "Renamed", isArchived: true }))
      const restored = await run(db.updateWorkspace(first.id, { isArchived: false }))
      expect(restored.sidebarPosition).toBe(earlier)
      expect(restored.sidebarOrderRevision).toBe(4)
      const upserted = await run(db.upsertWorkspace({ ...request, id: first.id }))
      expect(upserted.sidebarPosition).toBe(earlier)
      expect(
        (await run(db.listWorkspaces)).find((row) => row.id === sibling.id)?.sidebarPosition
      ).toBe(sibling.sidebarPosition)
    } finally {
      await run(db.close)
    }
  })
})

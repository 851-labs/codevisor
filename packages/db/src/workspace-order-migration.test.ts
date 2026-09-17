import { initialWorkspacePosition } from "@codevisor/api"
import Database from "better-sqlite3"
import { expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

it("initializes existing workspaces from creation dates without importing client order", async () => {
  const filename = tempDatabase()
  const db = await run(makeDatabase({ filename, serverId: "local" }))
  try {
    const project = await run(db.createProject({ folderPath: "/tmp/workspace-order-migration" }))
    for (const [id, createdAt] of [
      ["older", "2026-01-01T00:00:00Z"],
      ["newer", "2026-02-01T00:00:00Z"],
      ["undated", "invalid"]
    ]) {
      await run(
        db.upsertWorkspace({
          id: id!,
          createdAt: createdAt!,
          projectId: project.id,
          name: id!,
          hasCustomName: false
        })
      )
    }
  } finally {
    await run(db.close)
  }
  const sqlite = new Database(filename)
  try {
    sqlite.exec(`
      drop index workspaces_sidebar_position;
      alter table workspaces drop column sidebar_position;
      alter table workspaces drop column sidebar_order_revision;
      delete from schema_migrations where id = 47;
    `)
  } finally {
    sqlite.close()
  }
  const upgraded = await run(makeDatabase({ filename, serverId: "local" }))
  try {
    const rows = await run(upgraded.listWorkspaces)
    expect(rows.map((row) => row.id)).toEqual(["newer", "older", "undated"])
    expect(rows[0]?.sidebarPosition).toBe(
      initialWorkspacePosition(Date.parse("2026-02-01T00:00:00Z"), "newer")
    )
    expect(rows[2]?.sidebarPosition).toBe(initialWorkspacePosition(0, "undated"))
    expect(rows.every((row) => row.sidebarOrderRevision === 1)).toBe(true)
  } finally {
    await run(upgraded.close)
  }
})

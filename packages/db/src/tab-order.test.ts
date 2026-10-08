import Database from "better-sqlite3"
import { describe, expect, it } from "vitest"

import { DatabaseError, makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const paneIds = [
  "00000000-0000-0000-0000-00000000000a",
  "00000000-0000-0000-0000-00000000000b",
  "00000000-0000-0000-0000-00000000000c"
] as const
const [chat, terminal, browser] = paneIds

/// A workspace with three tabs, created in order.
const seed = async (filename: string) => {
  const db = await run(makeDatabase({ filename, serverId: "local" }))
  const project = await run(db.createProject({ folderPath: "/tmp/tab-order" }))
  const workspace = await run(
    db.upsertWorkspace({ projectId: project.id, name: "tabs", hasCustomName: false })
  )
  for (const [id, title] of [
    [chat, "Chat"],
    [terminal, "Terminal"],
    [browser, "Browser"]
  ] as const) {
    await run(
      db.upsertWorkspacePane(workspace.id, {
        id,
        providerId: "codevisor",
        paneType: "terminal",
        title
      })
    )
  }
  return { db, workspace }
}

describe("@codevisor/db shared tab order", () => {
  it("lists listed panes first, then the rest in their current order", async () => {
    const { db, workspace } = await seed(tempDatabase())
    const titles = async () =>
      (await run(db.listWorkspacePanes))
        .filter((pane) => pane.workspaceId === workspace.id)
        .map((pane) => pane.title)
    expect(await titles()).toEqual(["Chat", "Terminal", "Browser"])

    const other = await run(
      db.upsertWorkspace({ projectId: workspace.projectId, name: "other", hasCustomName: false })
    )
    const foreign = await run(
      db.upsertWorkspacePane(other.id, {
        id: "foreign-pane",
        providerId: "codevisor",
        paneType: "terminal",
        title: "Other"
      })
    )
    const before = (await run(db.listWorkspacePanes)).filter(
      (pane) => pane.workspaceId === workspace.id
    )

    // UUID aliases deduplicate; unknown and foreign ids cannot join this workspace.
    const reordered = await run(
      db.reorderWorkspacePanes(workspace.id, [
        browser.toUpperCase(),
        "not-a-pane",
        foreign.id,
        browser
      ])
    )
    expect(reordered.map((pane) => pane.title)).toEqual(["Browser", "Chat", "Terminal"])
    expect(await titles()).toEqual(["Browser", "Chat", "Terminal"])
    for (const pane of reordered) {
      const {
        position: _position,
        updatedAt: _updatedAt,
        ...content
      } = before.find((original) => original.id === pane.id)!
      expect(pane).toMatchObject(content)
    }
    expect((await run(db.listWorkspacePanes)).find((pane) => pane.id === foreign.id)).toEqual(
      foreign
    )
    await run(db.close)
  })

  it("rolls back every pane when a later position write fails", async () => {
    const filename = tempDatabase()
    const { db, workspace } = await seed(filename)
    const sqlite = new Database(filename)
    try {
      const before = await run(db.listWorkspacePanes)
      // Browser writes first; abort Chat's second write after a real change.
      sqlite.exec(`
        create trigger reject_pane_move before update of position on workspace_panes
        when old.id = '${chat}'
        begin select raise(abort, 'reorder blocked'); end;
      `)
      const failure = await run(db.reorderWorkspacePanes(workspace.id, [browser])).catch(
        (error: unknown) => error
      )
      expect(failure).toBeInstanceOf(DatabaseError)
      expect(failure).toMatchObject({
        operation: "reorderWorkspacePanes",
        message: "reorder blocked"
      })
      expect(await run(db.listWorkspacePanes)).toEqual(before)
    } finally {
      sqlite.exec("drop trigger if exists reject_pane_move")
      sqlite.close()
      await run(db.close)
    }
  })

  it("moves a tab without counting it as a content change", async () => {
    const { db, workspace } = await seed(tempDatabase())
    const before = (await run(db.listWorkspacePanes)).find((pane) => pane.id === browser)!

    const moved = await run(
      db.updateWorkspacePane(workspace.id, browser, { position: "0000000000018" })
    )
    expect(moved).toMatchObject({ position: "0000000000018", revision: before.revision })
    expect((await run(db.listWorkspacePanes))[0]?.id).toBe(browser)

    // Anything besides the position is still an edit.
    const renamed = await run(
      db.updateWorkspacePane(workspace.id, browser, { title: "Docs", position: "0000000000019" })
    )
    expect(renamed.revision).toBeGreaterThan(before.revision)
    await run(db.close)
  })

  it("starts existing tabs in creation order when upgrading", async () => {
    const filename = tempDatabase()
    const { db } = await seed(filename)
    await run(db.close)

    // Rewind migration 55 and give the rows creation times out of id order;
    // an unreadable time sorts first rather than failing the upgrade.
    const sqlite = new Database(filename)
    sqlite.exec(`
      alter table workspace_panes drop column position;
      delete from schema_migrations where id = 55;
    `)
    const setCreated = sqlite.prepare("update workspace_panes set created_at = ? where id = ?")
    setCreated.run("2026-06-02T00:00:00.000Z", chat)
    setCreated.run("2026-06-01T00:00:00.000Z", terminal)
    setCreated.run("unknown", browser)
    sqlite.close()

    const upgraded = await run(makeDatabase({ filename, serverId: "local" }))
    expect((await run(upgraded.listWorkspacePanes)).map((pane) => pane.title)).toEqual([
      "Browser",
      "Terminal",
      "Chat"
    ])
    await run(upgraded.close)
  })
})

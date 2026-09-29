import { expect, it } from "vitest"

import { memoryDatabase, run } from "./test-support.js"

const PANE_1 = "00000000-0000-4000-8000-000000000001"
const PANE_2 = "00000000-0000-4000-8000-000000000002"

const workspaceWithPanes = async () => {
  const fixture = await memoryDatabase()
  const { db, project } = fixture
  const workspace = await run(
    db.upsertWorkspace({ projectId: project.id, name: "work", hasCustomName: false })
  )
  const pane = (id: string, resourceKind: string, resourceId: string) =>
    run(
      db.upsertWorkspacePane(workspace.id, {
        id,
        providerId: "codevisor",
        paneType: resourceKind,
        title: "Terminal",
        resourceKind,
        resourceId
      })
    )
  await pane(PANE_1, "terminal", "Term-1")
  await pane(PANE_2, "terminal", "term-2")
  const statuses = async () =>
    Object.fromEntries(
      (await run(db.listWorkspacePanes)).map((row) => [
        row.resourceId,
        [row.liveTitle, row.terminalActivity]
      ])
    )
  return { ...fixture, workspace, pane, statuses }
}

it("sets a terminal's live title and activity on its panes and journals only real changes", async () => {
  const { db, statuses } = await workspaceWithPanes()

  // Keys match pane resource ids case-insensitively, as terminal routes do.
  const events = await run(db.setTerminalPaneStatus("term-1", "Claude Code", "working"))
  expect(events.map((event) => [event.kind, event.payload])).toEqual([
    ["navigation.changed", { table: "workspace_panes" }]
  ])
  expect(await statuses()).toEqual({
    "Term-1": ["Claude Code", "working"],
    "term-2": [undefined, undefined]
  })
  // The navigation delta clients consume carries it.
  const delta = await run(db.readSyncBatch(events[0]!.id - 1))
  expect(delta.events.at(-1)?.payload).toMatchObject({
    panes: [{ resourceId: "Term-1", liveTitle: "Claude Code", terminalActivity: "working" }]
  })

  // An unchanged status journals nothing, so settled repeats cost no events.
  expect(await run(db.setTerminalPaneStatus("TERM-1", "Claude Code", "working"))).toEqual([])
  expect(await run(db.setTerminalPaneStatus("term-2", "vim", undefined))).toHaveLength(1)
  expect(await statuses()).toEqual({
    "Term-1": ["Claude Code", "working"],
    "term-2": ["vim", undefined]
  })
  // The terminal exiting clears both.
  await run(db.setTerminalPaneStatus("term-1", undefined, undefined))
  expect((await statuses())["Term-1"]).toEqual([undefined, undefined])
})

it("keeps terminal status through client pane writes until the pane shows another resource", async () => {
  const { db, workspace, pane, statuses } = await workspaceWithPanes()
  await run(db.setTerminalPaneStatus("term-1", "Claude Code", "working"))
  await run(db.setTerminalPaneStatus("term-2", "Claude Code", "idle"))

  // Clients never send the fields: rewriting a pane keeps the server's.
  await pane(PANE_1, "terminal", "TERM-1")
  await run(db.updateWorkspacePane(workspace.id, PANE_2, { title: "Renamed" }))
  expect(await statuses()).toEqual({
    "TERM-1": ["Claude Code", "working"],
    "term-2": ["Claude Code", "idle"]
  })

  // Pointing a pane at another terminal drops the previous terminal's status.
  await pane(PANE_1, "terminal", "term-3")
  await run(db.updateWorkspacePane(workspace.id, PANE_2, { resourceId: "term-4" }))
  expect(await statuses()).toEqual({
    "term-3": [undefined, undefined],
    "term-4": [undefined, undefined]
  })
})

it("drops terminal status when a terminal pane becomes a chat", async () => {
  const { db, session, workspace, statuses } = await workspaceWithPanes()
  await run(db.setTerminalPaneStatus("term-1", "Claude Code", "working"))
  await run(db.promoteWorkspacePaneToSession(workspace.id, PANE_1, session.id, "Chat"))
  expect((await statuses())[session.id]).toEqual([undefined, undefined])
})

it("clears every live title and activity for a boot", async () => {
  const { db, statuses } = await workspaceWithPanes()
  await run(db.setTerminalPaneStatus("term-1", "Claude Code", "idle"))
  await run(db.setTerminalPaneStatus("term-2", "Claude Code", "working"))

  expect(await run(db.clearTerminalPaneStatuses)).toHaveLength(2)
  expect(await statuses()).toEqual({
    "Term-1": [undefined, undefined],
    "term-2": [undefined, undefined]
  })
  expect(await run(db.clearTerminalPaneStatuses)).toEqual([])
})

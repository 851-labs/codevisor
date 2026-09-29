import type { EventEnvelope, TerminalActivity } from "@codevisor/api"
import type { TerminalTitleListener } from "@codevisor/terminal"
import { Effect } from "effect"
import { expect, it, onTestFinished, vi } from "vitest"

import { makeEventFanout, run } from "../server-context.js"
import { makeServices } from "../test-support.js"
import { forwardTerminalTitles } from "./terminal-titles.js"

const fixture = async () => {
  const { services } = await makeServices()
  const { db } = services
  const project = await run(db.createProject({ folderPath: "/tmp/terminal-titles" }))
  const workspace = await run(
    db.upsertWorkspace({ projectId: project.id, name: "work", hasCustomName: false })
  )
  await run(
    db.upsertWorkspacePane(workspace.id, {
      id: "00000000-0000-4000-8000-000000000001",
      providerId: "codevisor",
      paneType: "terminal",
      title: "Terminal",
      resourceKind: "terminal",
      resourceId: "term-1"
    })
  )
  // The manager's settling is its own; this drives its listener directly.
  let listener: TerminalTitleListener | undefined
  const terminal = {
    ...services.terminal,
    subscribeTitles: (next: TerminalTitleListener) => {
      listener = next
      return () => {
        listener = undefined
      }
    }
  }
  const fanout = await run(makeEventFanout)
  const published: Array<EventEnvelope> = []
  fanout.subscribe((event) => published.push(event))
  const pane = async () => (await run(db.listWorkspacePanes))[0]
  return { db, terminal, fanout, published, pane, emit: () => listener }
}

it("puts settled titles and activity on the terminal's panes and wakes event readers", async () => {
  const { db, terminal, fanout, published, pane, emit } = await fixture()
  // A status left by the previous boot's terminal no longer applies.
  await run(db.setTerminalPaneStatus("term-1", "stale", "idle"))

  const close = forwardTerminalTitles(db, terminal, fanout)
  emit()?.("TERM-1", { title: "Claude Code", activity: "working" })
  emit()?.("term-1", { title: "Claude Code", activity: "working" })
  emit()?.("other-terminal", { title: "vim", activity: undefined })
  await close()

  expect(await pane()).toMatchObject({
    liveTitle: "Claude Code",
    terminalActivity: "working"
  })
  // Only the journaled changes are published (the boot clear and the new
  // status), not a second event per change.
  expect(published.map((event) => [event.kind, event.payload])).toEqual([
    ["navigation.changed", { table: "workspace_panes" }],
    ["navigation.changed", { table: "workspace_panes" }]
  ])
  // Detached on close.
  expect(emit()).toBeUndefined()
})

it("logs a failed write and keeps applying later titles", async () => {
  const { db, terminal, fanout, pane, emit } = await fixture()
  const errors = vi.spyOn(console, "error").mockImplementation(() => undefined)
  onTestFinished(() => errors.mockRestore())
  const failing = {
    ...db,
    setTerminalPaneStatus: (
      key: string,
      title: string | undefined,
      activity: TerminalActivity | undefined
    ) =>
      key === "broken"
        ? Effect.die(new Error("disk full"))
        : db.setTerminalPaneStatus(key, title, activity)
  }

  const close = forwardTerminalTitles(failing, terminal, fanout)
  emit()?.("broken", { title: "vim", activity: undefined })
  emit()?.("term-1", { title: "htop", activity: undefined })
  await close()

  expect((await pane())?.liveTitle).toBe("htop")
  expect(errors).toHaveBeenCalledExactlyOnceWith(
    expect.stringMatching(/^Terminal title sync failed: .*disk full/)
  )
})

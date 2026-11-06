import Database from "better-sqlite3"
import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const archivedChatFixture = async () => {
  const filename = tempDatabase()
  const db = await run(makeDatabase({ filename, serverId: "local" }))
  const project = await run(db.createProject({ folderPath: "/tmp/archived-turn" }))
  const session = await run(db.createSession({ projectId: project.id, harnessId: "claude-code" }))
  const workspace = await run(
    db.upsertWorkspace({ projectId: project.id, name: "Agent", hasCustomName: false })
  )
  await run(db.setSessionWorkspace(session.id, workspace.id))
  const update = (payload: Record<string, unknown>) =>
    run(db.appendEvent("session.updated", session.id, payload))
  return {
    db,
    filename,
    session,
    sidebarState: async () => (await run(db.getSessionSummary(session.id))).sidebarState,
    setArchived: (isArchived: boolean) => run(db.updateWorkspace(workspace.id, { isArchived })),
    startTurn: () => update({ initiatedBy: "user", turnId: "turn-1", turnState: "started" }),
    run: () => update({ runtimeState: "running" }),
    ask: () =>
      run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "question",
          questionId: "question-1",
          questions: [
            { id: "go", question: "Go?", options: [{ label: "Yes" }], allowsOther: false }
          ]
        })
      ),
    endTurn: () =>
      update({ initiatedBy: "user", stopReason: "end_turn", turnId: "turn-1", turnState: "ended" })
  }
}

describe("archived chat turns", () => {
  it("stops showing a chat archived mid-turn as working, even when its turn ends late", async () => {
    const chat = await archivedChatFixture()
    await chat.startTurn()
    await chat.run()
    await run(chat.db.createPromptQueueItem(chat.session.id, "queued"))
    expect(await chat.sidebarState()).toBe("inProgress")

    await chat.setArchived(true)
    expect(await chat.sidebarState()).toBe("idle")

    await chat.run()
    await chat.endTurn()
    expect(await chat.sidebarState()).not.toBe("inProgress")

    await chat.setArchived(false)
    expect(await chat.sidebarState()).not.toBe("inProgress")
  })

  it("stops showing a chat archived on an unanswered question as waiting for you", async () => {
    const chat = await archivedChatFixture()
    await chat.ask()
    expect(await chat.sidebarState()).toBe("waitingForUser")

    await chat.setArchived(true)
    expect(await chat.sidebarState()).not.toBe("waitingForUser")

    await chat.setArchived(false)
    expect(await chat.sidebarState()).toBe("waitingForUser")
  })

  it("repairs a chat a previous version left working inside an archived workspace", async () => {
    const chat = await archivedChatFixture()
    await chat.startTurn()
    await chat.setArchived(true)
    const raw = new Database(chat.filename)
    raw
      .prepare("update session_attention set turn_active = 1 where session_id = ?")
      .run(chat.session.id)
    raw
      .prepare("update sessions set sidebar_state = 'inProgress' where id = ?")
      .run(chat.session.id)
    raw.close()
    expect(await chat.sidebarState()).toBe("inProgress")

    await run(chat.db.retireSessionTurn(chat.session.id))
    expect(await chat.sidebarState()).toBe("idle")

    await chat.setArchived(false)
    expect(await chat.sidebarState()).toBe("idle")
  })
})

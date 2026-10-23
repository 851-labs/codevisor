import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const openDatabase = async () => {
  const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "machine-a" }))
  onTestFinished(() => run(db.close))
  return db
}

const message = (id: string, machineId: string, createdAt = "2100-01-01T00:00:00.000Z") => ({
  id,
  machineId,
  path: "fleet.session_event",
  args: { deliveryId: id },
  origin: { machineId: "machine-a", machineName: "A", sessionId: "s-1" },
  createdAt
})

describe("fleet outbox storage", () => {
  it("keeps queued messages in the order they were sent until each is removed", async () => {
    const db = await openDatabase()
    for (const id of ["z-first", "a-second", "m-third"]) {
      await run(db.enqueueFleetMessage(message(id, "machine-b")))
    }

    await run(db.deleteFleetMessage("a-second"))

    expect(await run(db.listFleetMessages)).toEqual([
      message("z-first", "machine-b"),
      message("m-third", "machine-b")
    ])
  })

  it("lists one machine's messages and expires old ones without touching newer ones", async () => {
    const db = await openDatabase()
    await run(db.enqueueFleetMessage(message("old", "machine-b", "2099-12-01T00:00:00.000Z")))
    await run(db.enqueueFleetMessage(message("other", "machine-c")))
    await run(db.enqueueFleetMessage(message("new", "machine-b")))

    await run(db.deleteFleetMessagesBefore("2099-12-15T00:00:00.000Z"))

    expect((await run(db.listFleetMessagesFor("machine-b"))).map((m) => m.id)).toEqual(["new"])
    expect((await run(db.listFleetMessages)).map((m) => m.id)).toEqual(["other", "new"])
  })

  it("queues a delivered prompt and its receipt together, once per delivery id", async () => {
    const db = await openDatabase()
    const project = await run(db.createProject({ folderPath: "/tmp/fleet-prompt" }))
    const bot = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    const prompt = (deliveryId: string, sessionId: string, receivedAt: string) =>
      run(db.acceptFleetPrompt({ deliveryId, receivedAt, sessionId, text: `event ${deliveryId}` }))

    const missingChat = await run(
      db.acceptFleetPrompt({
        deliveryId: "d-1",
        receivedAt: "2100-01-01T00:00:00.000Z",
        sessionId: "no-such-chat",
        text: "lost"
      })
    ).then(
      () => "accepted",
      () => "failed"
    )
    const first = await prompt("d-1", bot.id, "2100-01-01T00:00:00.000Z")
    const repeat = await prompt("d-1", bot.id, "2100-01-02T00:00:00.000Z")
    await run(db.pruneFleetDeliveries("2100-01-01T00:00:00.001Z"))
    const afterPrune = await prompt("d-1", bot.id, "2100-01-03T00:00:00.000Z")

    expect(missingChat).toBe("failed")
    expect([first, repeat, afterPrune]).toEqual([true, false, true])
    expect((await run(db.listPromptQueue(bot.id))).map((item) => [item.text, item.origin])).toEqual(
      [
        ["event d-1", "system"],
        ["event d-1", "system"]
      ]
    )
  })

  it("records a remote bot child's finished turns with the event and promotes each once", async () => {
    const db = await openDatabase()
    const project = await run(db.createProject({ folderPath: "/tmp/fleet-turns" }))
    const parent = "remote2:machine-b:bot-chat"
    const { session: child } = await run(
      db.createWorkspaceWithSession({
        workspace: {
          id: "ws-linked",
          projectId: project.id,
          name: "Linked",
          hasCustomName: false,
          botId: "6d1f0c35-2a64-4f3e-9d0a-3b7f3c1c9a10",
          botMachineId: "machine-b",
          botParentSessionId: parent
        },
        session: { projectId: project.id, harnessId: "codex", parentSessionId: parent }
      })
    )
    const plain = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    const update = (sessionId: string, payload: Record<string, unknown>) =>
      run(db.appendEvent("session.updated", sessionId, payload))
    await update(child.id, { turnState: "running" })
    await update(child.id, { turnState: "ended", stopKind: "pausedForUpdate" })
    const ended = await update(child.id, { turnState: "ended", stopReason: "end_turn" })
    const bare = await update(child.id, { turnState: "ended" })
    await update(plain.id, { turnState: "ended" })

    const pending = await run(db.listFleetPendingTurns)
    await run(db.promoteFleetTurn(pending[0]!, message("turn-1", "machine-b")))
    await run(db.enqueueFleetMessage(message("turn-1", "machine-c")))
    await run(db.promoteFleetTurn(pending[0]!, undefined))
    await run(db.promoteFleetTurn(pending[1]!, undefined))

    expect(pending).toEqual([
      { sessionId: child.id, revision: ended.subjectRevision, stopReason: "end_turn" },
      { sessionId: child.id, revision: bare.subjectRevision }
    ])
    expect(await run(db.listFleetPendingTurns)).toEqual([])
    expect((await run(db.listFleetMessages)).map((m) => [m.id, m.machineId])).toEqual([
      ["turn-1", "machine-b"]
    ])
  })
})

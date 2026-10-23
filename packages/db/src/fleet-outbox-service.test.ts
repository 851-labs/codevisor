import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const openDatabase = async () => {
  const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "machine-a" }))
  onTestFinished(() => run(db.close))
  return db
}

const linkedChild = async (db: Awaited<ReturnType<typeof openDatabase>>) => {
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
  return { child, plain }
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

  it("hands out a machine's next unexpired message and expires old ones", async () => {
    const db = await openDatabase()
    await run(db.enqueueFleetMessage(message("old", "machine-b", "2099-12-01T00:00:00.000Z")))
    await run(db.enqueueFleetMessage(message("other", "machine-c")))
    await run(db.enqueueFleetMessage(message("new", "machine-b")))

    const cutoff = "2099-12-15T00:00:00.000Z"
    const next = await run(db.nextFleetMessageFor("machine-b", cutoff))
    await run(db.expireFleetBefore(cutoff))

    expect(next?.id).toBe("new")
    expect(await run(db.nextFleetMessageFor("machine-d", cutoff))).toBeUndefined()
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

  it("records each finished turn of a remote bot's child with its own reply and end time", async () => {
    const db = await openDatabase()
    const { child, plain } = await linkedChild(db)
    const reply = (text: string) =>
      run(db.appendConversationItem(child.id, "assistant", undefined, text, false))
    const update = (sessionId: string, payload: Record<string, unknown>) =>
      run(db.appendEvent("session.updated", sessionId, payload))

    await reply("FIRST REPORT")
    await update(child.id, { turnState: "running" })
    await update(child.id, { turnState: "ended", stopKind: "pausedForUpdate" })
    const first = await update(child.id, { turnState: "ended", stopReason: "end_turn" })
    await reply("SECOND REPORT")
    const second = await update(child.id, { turnState: "ended" })
    await reply("STILL STREAMING")
    await update(plain.id, { turnState: "ended" })

    expect(await run(db.listFleetPendingTurns)).toEqual([
      {
        sessionId: child.id,
        revision: first.subjectRevision,
        stopReason: "end_turn",
        endedAt: first.createdAt,
        finalText: "FIRST REPORT"
      },
      {
        sessionId: child.id,
        revision: second.subjectRevision,
        endedAt: second.createdAt,
        finalText: "SECOND REPORT"
      }
    ])
  })

  it("promotes a pending turn once, never after its message was acknowledged, and expires old turns", async () => {
    const db = await openDatabase()
    const { child } = await linkedChild(db)
    await run(db.appendEvent("session.updated", child.id, { turnState: "ended" }))
    await run(db.appendEvent("session.updated", child.id, { turnState: "ended" }))
    const [first, second] = await run(db.listFleetPendingTurns)

    await run(db.promoteFleetTurn(first!, message("turn-1", "machine-b")))
    await run(db.deleteFleetMessage("turn-1"))
    await run(db.promoteFleetTurn(first!, message("turn-1", "machine-b")))
    await run(db.expireFleetBefore("2999-01-01T00:00:00.000Z"))
    await run(db.promoteFleetTurn(second!, message("turn-2", "machine-b")))

    expect(await run(db.listFleetMessages)).toEqual([])
    expect(await run(db.listFleetPendingTurns)).toEqual([])
  })
})

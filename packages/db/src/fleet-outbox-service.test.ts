import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished, vi } from "vitest"

import { makeDatabase, type FleetMessage } from "./index.js"
import { rowReader, text } from "./row-reader.js"
import { ATTENTION_SETTLE_GRACE_MS } from "./session-attention.js"
import { run, tempDatabase } from "./test-support.js"

const planRows = rowReader({ detail: text })

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

const queueThroughTurns = async (
  db: Awaited<ReturnType<typeof openDatabase>>,
  messages: ReadonlyArray<FleetMessage>
) => {
  const { child } = await linkedChild(db)
  for (const queued of messages) {
    const turnId = queued.id
    await run(db.appendEvent("session.updated", child.id, { turnState: "started", turnId }))
    await run(db.appendEvent("session.updated", child.id, { turnState: "ended", turnId }))
    const [turn] = await run(db.listFleetPendingTurns)
    await run(db.promoteFleetTurn(turn!, queued))
  }
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
    await queueThroughTurns(
      db,
      ["z-first", "a-second", "m-third"].map((id) => message(id, "machine-b"))
    )

    await run(db.deleteFleetMessage("a-second"))

    expect(await run(db.listFleetMessages)).toEqual([
      message("z-first", "machine-b"),
      message("m-third", "machine-b")
    ])
  })

  it("hands out a machine's next unexpired message and expires old ones", async () => {
    const db = await openDatabase()
    await queueThroughTurns(db, [
      message("old", "machine-b", "2099-12-01T00:00:00.000Z"),
      message("other", "machine-c"),
      message("new", "machine-b")
    ])

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
    const event = (kind: "session.updated" | "session.output", payload: object) =>
      run(db.appendEvent(kind, child.id, payload))
    const turn = async (turnId: string, reply: string | undefined, end: object | undefined) => {
      await event("session.updated", { turnState: "started", turnId })
      if (reply !== undefined) {
        await event("session.output", {
          sessionUpdate: "assistant_message_finalized",
          markdown: reply,
          turnId
        })
      }
      if (end === undefined) return undefined
      return event("session.updated", { turnState: "ended", turnId, ...end })
    }

    await event("session.updated", { turnState: "ended", stopKind: "pausedForUpdate" })
    const old = await turn("t-1", "OLD REPORT", { stopReason: "end_turn" })
    const empty = await turn("t-2", undefined, {})
    await turn("t-3", "STILL STREAMING", undefined)
    await run(db.appendEvent("session.updated", plain.id, { turnState: "ended" }))

    expect(await run(db.listFleetPendingTurns)).toEqual([
      {
        sessionId: child.id,
        revision: old!.subjectRevision,
        stopReason: "end_turn",
        endedAt: old!.createdAt,
        finalText: "OLD REPORT"
      },
      {
        sessionId: child.id,
        revision: empty!.subjectRevision,
        endedAt: empty!.createdAt,
        finalText: ""
      }
    ])
  })

  it("sends a remote bot's held child turn once it settles, without marking it unread", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    onTestFinished(() => {
      vi.useRealTimers()
    })
    const db = await openDatabase()
    const { child } = await linkedChild(db)
    const event = (payload: object) => run(db.appendEvent("session.updated", child.id, payload))

    await event({ turnState: "started", turnId: "t-1" })
    await event({
      backgroundTasks: [
        { id: "a-1", description: "Research", status: "running", taskType: "subagent" }
      ]
    })
    const ended = await event({ turnState: "ended", turnId: "t-1", stopReason: "end_turn" })
    const whileHeld = await run(db.listFleetPendingTurns)
    await event({ backgroundTasks: [] })
    vi.setSystemTime(new Date(Date.now() + ATTENTION_SETTLE_GRACE_MS))
    await run(db.settleSessionAttention(child.id))

    expect(whileHeld).toEqual([])
    expect(await run(db.listFleetPendingTurns)).toEqual([
      expect.objectContaining({ sessionId: child.id, revision: ended.subjectRevision })
    ])
    expect((await run(db.getSessionSummary(child.id))).latestAttentionSequence).toBe(0)
  })

  it("finds a machine's next message through an index, without scanning the outbox", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
    await run(db.close)
    const sqlite = new Database(filename, { readonly: true })
    onTestFinished(() => {
      sqlite.close()
    })

    const plan = planRows
      .all(
        sqlite
          .prepare(
            `explain query plan select * from fleet_outbox
             where machine_id = ? and created_at >= ? order by rowid limit 1`
          )
          .all("machine-b", "2100-01-01T00:00:00.000Z")
      )
      .map((row) => row.detail)

    expect(plan).toEqual([
      expect.stringContaining("USING INDEX fleet_outbox_machine (machine_id=?)")
    ])
  })

  it("promotes a pending turn once, never after its message was acknowledged, and expires old turns", async () => {
    const db = await openDatabase()
    const { child } = await linkedChild(db)
    for (const turnId of ["t-1", "t-2"]) {
      await run(db.appendEvent("session.updated", child.id, { turnState: "started", turnId }))
      await run(db.appendEvent("session.updated", child.id, { turnState: "ended", turnId }))
    }
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

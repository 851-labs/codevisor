import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase, type FleetMessage } from "./index.js"
import { rowReader, text } from "./row-reader.js"
import { run, tempDatabase } from "./test-support.js"

const planRows = rowReader({ detail: text })

const openDatabase = async () => {
  const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "machine-a" }))
  onTestFinished(() => run(db.close))
  return db
}

const queueAll = async (
  db: Awaited<ReturnType<typeof openDatabase>>,
  messages: ReadonlyArray<FleetMessage>
) => {
  for (const queued of messages) await run(db.enqueueFleetMessage(queued))
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
  it("keeps queued messages once each, in the order they were sent, until each is removed", async () => {
    const db = await openDatabase()
    await queueAll(
      db,
      ["z-first", "a-second", "m-third", "z-first"].map((id) => message(id, "machine-b"))
    )

    await run(db.deleteFleetMessage("a-second"))

    expect(await run(db.listFleetMessages)).toEqual([
      message("z-first", "machine-b"),
      message("m-third", "machine-b")
    ])
  })

  it("hands out a machine's next unexpired message and expires old ones", async () => {
    const db = await openDatabase()
    await queueAll(db, [
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
})

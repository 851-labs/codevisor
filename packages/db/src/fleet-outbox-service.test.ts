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

  it("remembers each delivery id once until it is pruned", async () => {
    const db = await openDatabase()

    const first = await run(db.recordFleetDelivery("d-1", "2100-01-01T00:00:00.000Z"))
    const repeat = await run(db.recordFleetDelivery("d-1", "2100-01-02T00:00:00.000Z"))
    await run(db.pruneFleetDeliveries("2100-01-01T00:00:00.001Z"))
    const afterPrune = await run(db.recordFleetDelivery("d-1", "2100-01-03T00:00:00.000Z"))

    expect([first, repeat, afterPrune]).toEqual([true, false, true])
  })
})

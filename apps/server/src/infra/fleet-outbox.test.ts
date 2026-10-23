import { CodeExecutionToolError } from "@codevisor/automation"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeServices, run } from "../test-support.js"
import {
  FLEET_DELIVERY_MEMORY_MS,
  FLEET_MESSAGE_MAX_AGE_MS,
  fleetLinkFor,
  forgetOldFleetDeliveries,
  makeFleetOutbox
} from "./fleet-outbox.js"
import type { MachineLink } from "./machine-link.js"

const NOW = Date.parse("2100-01-01T00:00:00.000Z")
const origin = { machineId: "machine-laptop", machineName: "Laptop", sessionId: "s-1" }

const linkAnswering = (answer: (machine: string) => unknown) => {
  const sent: Array<{ readonly machine: string; readonly args: unknown }> = []
  const machines: MachineLink = {
    list: async () => [],
    resolve: () => undefined,
    machineIdOf: () => undefined,
    invoke: async (machine, _path, args) => {
      sent.push({ machine, args })
      const result = answer(machine)
      if (result instanceof Error) throw result
      return result
    }
  }
  return { machines, sent }
}

const unavailable = () =>
  new CodeExecutionToolError("offline", { code: "machine_unavailable", details: {} })

describe("fleet outbox", () => {
  it("delivers to reachable machines, keeps an offline machine's messages, and drops refusals", async () => {
    const { services } = await makeServices("outbox-a")
    const { machines, sent } = linkAnswering((machine) => {
      if (machine === "machine-offline") return unavailable()
      if (machine === "machine-refusing") return new Error("403 not that bot")
      return null
    })
    const outbox = makeFleetOutbox({ db: services.db, machines, now: () => NOW })

    await outbox.send("machine-offline", "fleet.session_event", { n: 1 }, origin)
    await outbox.send("machine-offline", "fleet.session_event", { n: 2 }, origin)
    await outbox.send("machine-refusing", "fleet.session_event", { n: 3 }, origin)
    await outbox.send("machine-studio", "fleet.session_event", "not a record", origin)

    const queued = await run(services.db.listFleetMessages)
    expect(queued.map((message) => message.args)).toEqual([
      { n: 1, deliveryId: queued[0]!.id },
      { n: 2, deliveryId: queued[1]!.id }
    ])
    expect(sent.map((call) => call.machine)).toEqual([
      "machine-offline",
      "machine-offline",
      "machine-offline",
      "machine-refusing",
      "machine-offline",
      "machine-studio"
    ])
    expect(sent.at(-1)?.args).toEqual({ deliveryId: expect.any(String) })
  })

  it("drops messages older than the retry window without sending them", async () => {
    const { services } = await makeServices("outbox-b")
    let now = NOW
    const { machines, sent } = linkAnswering(() => unavailable())
    const outbox = makeFleetOutbox({ db: services.db, machines, now: () => now })
    await outbox.send("machine-offline", "fleet.session_event", {}, origin)

    now = NOW + FLEET_MESSAGE_MAX_AGE_MS + 1
    await outbox.flush()

    expect(sent).toHaveLength(1)
    expect(await run(services.db.listFleetMessages)).toEqual([])
  })

  it("keeps flushing after a flush fails", async () => {
    const { services } = await makeServices("outbox-c")
    const { machines, sent } = linkAnswering(() => null)
    let failures = 1
    const db = {
      ...services.db,
      listFleetMessages: Effect.suspend(() =>
        failures-- > 0 ? Effect.die(new Error("disk")) : services.db.listFleetMessages
      )
    }
    const outbox = makeFleetOutbox({ db, machines, now: () => NOW })

    await expect(outbox.send("machine-studio", "fleet.session_event", {}, origin)).rejects.toThrow()
    await outbox.flush()

    expect(sent).toHaveLength(1)
    expect(await run(services.db.listFleetMessages)).toEqual([])
  })

  it("links only servers that know their machines, and forgets old delivery ids", async () => {
    const { services } = await makeServices("outbox-d")
    const { machines } = linkAnswering(() => null)
    const old = new Date(NOW - FLEET_DELIVERY_MEMORY_MS - 1).toISOString()
    const recent = new Date(NOW).toISOString()
    await run(services.db.recordFleetDelivery("old", old))
    await run(services.db.recordFleetDelivery("recent", recent))

    await forgetOldFleetDeliveries(services, NOW)

    expect(fleetLinkFor(services)).toBeUndefined()
    expect(fleetLinkFor({ ...services, machines })?.machines).toBe(machines)
    expect(await run(services.db.recordFleetDelivery("old", recent))).toBe(true)
    expect(await run(services.db.recordFleetDelivery("recent", recent))).toBe(false)
  })
})

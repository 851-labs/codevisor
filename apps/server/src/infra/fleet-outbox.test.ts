import { CodeExecutionToolError } from "@codevisor/automation"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeServices, run } from "../test-support.js"
import { field } from "../unknown-values.js"
import {
  FLEET_DELIVERY_MEMORY_MS,
  FLEET_MESSAGE_MAX_AGE_MS,
  fleetLinkFor,
  forgetOldFleetDeliveries,
  makeFleetOutbox,
  type FleetOutboxOptions
} from "./fleet-outbox.js"
import { PeerAnswerError, type MachineLink } from "./machine-link.js"

const NOW = Date.parse("2100-01-01T00:00:00.000Z")
const origin = { machineId: "machine-laptop", machineName: "Laptop", sessionId: "s-1" }

interface Attempt {
  readonly machine: string
  readonly args: unknown
  readonly signal: AbortSignal | undefined
}

const recordingLink = (answer: (attempt: Attempt) => Promise<unknown>) => {
  const attempts: Attempt[] = []
  const machines: MachineLink = {
    list: async () => [],
    resolve: () => undefined,
    machineIdOf: () => undefined,
    invoke: (machine, _path, args, _origin, signal) => {
      const attempt = { machine, args, signal }
      attempts.push(attempt)
      return answer(attempt)
    }
  }
  return { machines, attempts }
}

const gate = () => {
  let open!: () => void
  const opened = new Promise<void>((resolve) => {
    open = resolve
  })
  return { open, opened }
}

const untilAborted = (attempt: Attempt): Promise<never> =>
  new Promise((_resolve, reject) => {
    attempt.signal!.addEventListener("abort", () => reject(new Error("deadline")))
  })

const outboxFor = async (
  answer: (attempt: Attempt) => Promise<unknown>,
  overrides: Partial<FleetOutboxOptions> = {}
) => {
  const { services } = await makeServices("outbox")
  const { machines, attempts } = recordingLink(answer)
  const deadlines: AbortController[] = []
  const outbox = makeFleetOutbox({
    db: services.db,
    machines,
    now: () => NOW,
    attemptSignal: () => {
      const deadline = new AbortController()
      deadlines.push(deadline)
      return deadline.signal
    },
    ...overrides
  })
  const queued = async () =>
    (await run(services.db.listFleetMessages)).map((message) => message.args.n)
  return { services, outbox, attempts, deadlines, queued }
}

describe("fleet outbox", () => {
  it("drops only definitive refusals and retries everything else", async () => {
    const failures: Record<string, unknown> = {
      forbidden: new PeerAnswerError("not that bot", {}, 403),
      conflict: new PeerAnswerError("archived", {}, 409),
      crashed: new PeerAnswerError("boom", {}, 500),
      gateway: new PeerAnswerError("bad gateway", {}, 502),
      throttled: new PeerAnswerError("slow down", {}, 429),
      offline: new CodeExecutionToolError("offline", { code: "machine_unavailable" }),
      unknown: new Error("socket hang up")
    }
    const { outbox, queued } = await outboxFor(async (attempt) => {
      throw failures[attempt.machine]
    })

    for (const [n, machine] of Object.keys(failures).entries()) {
      await outbox.send(machine, "fleet.session_event", { n }, origin)
    }

    expect(await queued()).toEqual([2, 3, 4, 5, 6])
  })

  it("keeps delivering to other machines while one delivery stalls, until its deadline", async () => {
    const stall = gate()
    const { outbox, attempts, deadlines, queued } = await outboxFor((attempt) => {
      if (attempt.machine !== "machine-stalled") return Promise.resolve(null)
      stall.open()
      return untilAborted(attempt)
    })

    const stalled = outbox.send("machine-stalled", "fleet.session_event", { n: 1 }, origin)
    await stall.opened
    await outbox.send("machine-studio", "fleet.session_event", { n: 2 }, origin)
    const whileStalled = await queued()
    deadlines[0]!.abort()
    await stalled

    expect(whileStalled).toEqual([1])
    expect(attempts.map((attempt) => attempt.machine)).toEqual([
      "machine-stalled",
      "machine-studio"
    ])
    expect(await queued()).toEqual([1])
  })

  it("expires old messages even while their destination is stalled", async () => {
    let now = NOW
    const attemptStarted = gate()
    const { outbox, deadlines, queued } = await outboxFor(
      (attempt) => {
        attemptStarted.open()
        return untilAborted(attempt)
      },
      { now: () => now }
    )
    const stalled = outbox.send("machine-stalled", "fleet.session_event", { n: 1 }, origin)
    await attemptStarted.opened

    now = NOW + FLEET_MESSAGE_MAX_AGE_MS + 1
    await outbox.expire()
    const afterExpiry = await queued()
    deadlines[0]!.abort()
    await stalled

    expect(afterExpiry).toEqual([])
    expect(await queued()).toEqual([])
  })

  it("delivers messages sent during a delivery in order, in the same drain", async () => {
    const firstAnswer = gate()
    const { outbox, attempts, queued } = await outboxFor(async (attempt) => {
      if (field(attempt.args, "n") === 1) await firstAnswer.opened
      return null
    })

    const sendingFirst = outbox.send("machine-studio", "fleet.session_event", { n: 1 }, origin)
    const sendingSecond = outbox.send("machine-studio", "fleet.session_event", { n: 2 }, origin)
    firstAnswer.open()
    await Promise.all([sendingFirst, sendingSecond])

    expect(attempts.map((attempt) => attempt.args)).toEqual([
      expect.objectContaining({ n: 1 }),
      expect.objectContaining({ n: 2 })
    ])
    expect(await queued()).toEqual([])
  })

  it("keeps draining after a pass fails", async () => {
    const { services } = await makeServices("outbox-failing")
    const { machines, attempts } = recordingLink(async () => null)
    let failures = 1
    const db = {
      ...services.db,
      listFleetMessagesFor: (machineId: string) =>
        Effect.suspend(() =>
          failures-- > 0
            ? Effect.die(new Error("disk"))
            : services.db.listFleetMessagesFor(machineId)
        )
    }
    const outbox = makeFleetOutbox({ db, machines, now: () => NOW })

    await outbox.send("machine-studio", "fleet.session_event", {}, origin)
    await outbox.flush()

    expect(attempts).toHaveLength(1)
    expect(await run(services.db.listFleetMessages)).toEqual([])
  })

  it("links only servers that know their machines, and forgets old delivery ids", async () => {
    const { services } = await makeServices("outbox-link")
    const { machines } = recordingLink(async () => null)
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

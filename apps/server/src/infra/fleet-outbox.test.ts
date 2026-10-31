import { CodeExecutionToolError } from "@codevisor/automation"
import type { CodevisorDatabaseService, FleetMessage } from "@codevisor/db"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeServices, run, waitFor } from "../test-support.js"
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
    const signal = attempt.signal!
    if (signal.aborted) reject(new Error("deadline"))
    signal.addEventListener("abort", () => reject(new Error("deadline")))
  })

const queueThroughRemoteBotChild = async (db: CodevisorDatabaseService) => {
  const project = await run(db.createProject({ folderPath: "/tmp/fleet-outbox" }))
  const parentSessionId = "remote2:machine-remote:bot-chat"
  const { session: child } = await run(
    db.createWorkspaceWithSession({
      workspace: {
        id: "ws-fleet-outbox",
        projectId: project.id,
        name: "Child",
        hasCustomName: false,
        botId: "6d1f0c35-2a64-4f3e-9d0a-3b7f3c1c9a10",
        botMachineId: "machine-remote",
        botParentSessionId: parentSessionId
      },
      session: { projectId: project.id, harnessId: "codex", parentSessionId }
    })
  )
  return async (message: FleetMessage) => {
    const turnId = message.id
    await run(db.appendEvent("session.updated", child.id, { turnState: "started", turnId }))
    await run(db.appendEvent("session.updated", child.id, { turnState: "ended", turnId }))
    const [turn] = await run(db.listFleetPendingTurns)
    await run(db.promoteFleetTurn(turn!, message))
  }
}

const outboxFor = async (
  answer: (attempt: Attempt) => Promise<unknown>,
  overrides: Partial<FleetOutboxOptions> = {}
) => {
  const { services } = await makeServices("outbox")
  const { machines, attempts } = recordingLink(answer)
  const deadlines: AbortController[] = []
  let deadlinesPassed = false
  const outbox = makeFleetOutbox({
    db: services.db,
    machines,
    now: () => NOW,
    attemptSignal: () => {
      const deadline = new AbortController()
      if (deadlinesPassed) deadline.abort()
      deadlines.push(deadline)
      return deadline.signal
    },
    ...overrides
  })
  const passDeadlines = () => {
    deadlinesPassed = true
    for (const deadline of deadlines) deadline.abort()
  }
  const queued = async () =>
    (await run(services.db.listFleetMessages)).map((message) => message.args.n)
  const queue = await queueThroughRemoteBotChild(services.db)
  const enqueue = (machineId: string, args: Readonly<Record<string, unknown>>) =>
    queue({
      id: `m-${String(args.n)}-${machineId}`,
      machineId,
      path: "fleet.session_event",
      args,
      origin,
      createdAt: new Date(NOW).toISOString()
    })
  return { services, outbox, attempts, queued, enqueue, passDeadlines }
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
    const { outbox, queued, enqueue } = await outboxFor(async (attempt) => {
      throw failures[attempt.machine]
    })

    for (const [n, machine] of Object.keys(failures).entries()) await enqueue(machine, { n })
    await outbox.flush()

    expect(await queued()).toEqual([2, 3, 4, 5, 6])
  })

  it("keeps delivering to other machines while one delivery stalls, until its deadline", async () => {
    const stall = gate()
    const { outbox, attempts, queued, enqueue, passDeadlines } = await outboxFor((attempt) => {
      if (attempt.machine !== "machine-stalled") return Promise.resolve(null)
      stall.open()
      return untilAborted(attempt)
    })

    await enqueue("machine-stalled", { n: 1 })
    const stalled = outbox.flush()
    await stall.opened
    await enqueue("machine-studio", { n: 2 })
    const alongside = outbox.flush()
    await waitFor(async () => (await queued()).length === 1)
    const whileStalled = await queued()
    passDeadlines()
    await Promise.all([stalled, alongside])

    expect(whileStalled).toEqual([1])
    expect(attempts.map((attempt) => attempt.machine)).toEqual([
      "machine-stalled",
      "machine-studio",
      "machine-stalled"
    ])
    expect(await queued()).toEqual([1])
  })

  it("expires old messages even while their destination is stalled", async () => {
    let now = NOW
    const attemptStarted = gate()
    const { outbox, queued, enqueue, passDeadlines } = await outboxFor(
      (attempt) => {
        attemptStarted.open()
        return untilAborted(attempt)
      },
      { now: () => now }
    )
    await enqueue("machine-stalled", { n: 1 })
    const stalled = outbox.flush()
    await attemptStarted.opened

    now = NOW + FLEET_MESSAGE_MAX_AGE_MS + 1
    await outbox.expire()
    const afterExpiry = await queued()
    passDeadlines()
    await stalled

    expect(afterExpiry).toEqual([])
    expect(await queued()).toEqual([])
  })

  it("never sends a message that expired while the drain was busy with an earlier one", async () => {
    let now = NOW
    const expiredMidDrain = await outboxFor(
      async () => {
        now = NOW + FLEET_MESSAGE_MAX_AGE_MS + 1
        return null
      },
      { now: () => now }
    )
    await expiredMidDrain.enqueue("machine-studio", { n: 1 })
    await expiredMidDrain.enqueue("machine-studio", { n: 2 })

    await expiredMidDrain.outbox.flush()

    expect(expiredMidDrain.attempts.map((attempt) => field(attempt.args, "n"))).toEqual([1])
    expect(await expiredMidDrain.queued()).toEqual([2])
    await expiredMidDrain.outbox.expire()
    expect(await expiredMidDrain.queued()).toEqual([])
  })

  it("delivers messages queued during a delivery in order, in the same drain", async () => {
    const firstAnswer = gate()
    const firstAttempt = gate()
    const { outbox, attempts, queued, enqueue } = await outboxFor(async (attempt) => {
      if (field(attempt.args, "n") !== 1) return null
      firstAttempt.open()
      await firstAnswer.opened
      return null
    })

    await enqueue("machine-studio", { n: 1 })
    const draining = outbox.flush()
    await firstAttempt.opened
    await enqueue("machine-studio", { n: 2 })
    const joining = outbox.flush()
    firstAnswer.open()
    await Promise.all([draining, joining])

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
      nextFleetMessageFor: (machineId: string, notBefore: string) =>
        Effect.suspend(() =>
          failures-- > 0
            ? Effect.die(new Error("disk"))
            : services.db.nextFleetMessageFor(machineId, notBefore)
        )
    }
    const outbox = makeFleetOutbox({ db, machines, now: () => NOW })
    const queue = await queueThroughRemoteBotChild(services.db)

    await queue({
      id: "m",
      machineId: "machine-studio",
      path: "fleet.session_event",
      args: {},
      origin,
      createdAt: new Date(NOW).toISOString()
    })
    await outbox.flush()
    await outbox.flush()

    expect(attempts).toHaveLength(1)
    expect(await run(services.db.listFleetMessages)).toEqual([])
  })

  it("links only servers that know their machines, and forgets old delivery ids", async () => {
    const { services } = await makeServices("outbox-link")
    const { machines } = recordingLink(async () => null)
    const project = await run(services.db.createProject({ folderPath: "/tmp/outbox-link" }))
    const bot = await run(services.db.createSession({ projectId: project.id, harnessId: "codex" }))
    const accept = (deliveryId: string, receivedAt: number) =>
      run(
        services.db.acceptFleetPrompt({
          deliveryId,
          receivedAt: new Date(receivedAt).toISOString(),
          sessionId: bot.id,
          text: "t"
        })
      )
    await accept("old", NOW - FLEET_DELIVERY_MEMORY_MS - 1)
    await accept("recent", NOW)

    await forgetOldFleetDeliveries(services, NOW)

    expect(fleetLinkFor(services)).toBeUndefined()
    expect(fleetLinkFor({ ...services, machines })?.machines).toBe(machines)
    expect([await accept("old", NOW), await accept("recent", NOW)]).toEqual([true, false])
  })
})

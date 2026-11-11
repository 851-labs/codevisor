import {
  CALLER_AGENT_TICKET_HEADER,
  FLEET_CALLER_HEADER,
  FLEET_SESSION_EVENT_PATH,
  StartedAgent,
  decode
} from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { makeFleetOutbox } from "../infra/fleet-outbox.js"
import { jsonRequest, run, waitFor } from "../test-support.js"
import {
  createArgs,
  invokeAs,
  laptop,
  post,
  postInvoke,
  resultOf,
  startArgs,
  startedSession,
  startFleet,
  stranger,
  studio,
  workspaceOf,
  type Answer,
  type FleetMachine
} from "./fleet-test-support.js"

const refusedCreator = (answer: Answer) => {
  expect(answer.status).not.toBe(200)
  expect(JSON.stringify(answer.body)).toContain("Only the machine an agent runs on")
}

const escapeRegExp = (text: string): string => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")

const failureOf = (pending: Promise<unknown>): Promise<string> =>
  pending.then(
    () => "",
    (cause: unknown) => String(cause)
  )

const sessionCount = async (machine: FleetMachine) =>
  (await run(machine.services.db.listSessions)).length

const promptsMatching = (machine: FleetMachine, text: string) =>
  machine.agents.prompts.filter(([, input]) => typeof input === "string" && input.includes(text))
    .length

const turnEndedFor = (sessionId: string) => `type="session.turn_ended" agentId="${sessionId}"`

const eventOrigin = { machineId: laptop.id, machineName: laptop.name, sessionId: "child-1" }

const eventBody = (args: unknown) => ({ path: FLEET_SESSION_EVENT_PATH, args, origin: eventOrigin })

describe("agents started from another machine", () => {
  it("name their creator and its machine, and send it each turn's own reply", async () => {
    const { home, remote, parent, parentOrigin } = await startFleet()
    const reports = () =>
      home.agents.prompts.flatMap(([, input]) =>
        typeof input === "string" && input.includes('type="session.turn_ended"') ? [input] : []
      )

    const started = await home.machines.invoke(
      laptop.id,
      "codevisor.agents.start",
      startArgs("one"),
      parentOrigin
    )
    const child = await startedSession(remote, started)
    await waitFor(() => reports().length === 1)
    await post(remote, `/v1/sessions/${child.id}/prompt`, { text: "two" })
    await waitFor(() => reports().length === 2)

    expect(decode(StartedAgent)(started).subscribed).toBe(true)
    expect(child).toMatchObject({ createdByAgentId: parent.id, createdByAgentMachineId: studio.id })
    expect(await workspaceOf(remote, child)).not.toHaveProperty("botId")
    const opening = `<codevisor-event machine="Laptop" machineId="${laptop.id}" type="session.turn_ended" agentId="${child.id}" title="Fix the laptop"`
    expect(reports()).toEqual([
      expect.stringMatching(new RegExp(`^${escapeRegExp(opening)}.*\\nEcho: one\\n`, "s")),
      expect.stringMatching(new RegExp(`^${escapeRegExp(opening)}.*\\nEcho: two\\n`, "s"))
    ])
  })

  it("refuse a creator on another machine unless the call comes from that machine", async () => {
    const { home, remote, parentOrigin } = await startFleet()
    const start = { path: "codevisor.agents.start", args: startArgs("go"), origin: parentOrigin }
    const before = await sessionCount(remote)

    const anonymous = await postInvoke(remote.server.url, start)
    const impostor = await invokeAs(stranger, remote, start)
    const stolenKey = await invokeAs({ ...studio, publicKey: stranger.publicKey }, remote, start)
    const otherMachine = await failureOf(
      home.machines.invoke(laptop.id, "codevisor.agents.start", startArgs("go"), {
        ...parentOrigin,
        machineId: stranger.id
      })
    )
    const claimedCreator = { createdByAgentId: "x", createdByAgentMachineId: studio.id }
    const direct = await jsonRequest(remote.server, "/v1/sessions", {
      method: "POST",
      headers: { [CALLER_AGENT_TICKET_HEADER]: "forged" },
      body: JSON.stringify({ ...createArgs, ...claimedCreator })
    })
    const directWorkspace = await post(remote, "/v1/workspaces", {
      workspace: {
        id: "6d1f0c35-2a64-4f3e-9d0a-3b7f3c1c9a10",
        projectId: "laptop-project",
        name: "W",
        hasCustomName: true
      },
      session: { ...createArgs, ...claimedCreator }
    })

    for (const answer of [anonymous, impostor, stolenKey, direct, directWorkspace]) {
      refusedCreator(answer)
    }
    expect(otherMachine).toContain("Only the machine an agent runs on")
    expect(await sessionCount(remote)).toBe(before)
  })

  it("keep a turn end for an offline creator machine and deliver it once it is back", async () => {
    const { home, remote, parentOrigin, setOffline } = await startFleet()
    const outbox = makeFleetOutbox({
      db: remote.services.db,
      machines: remote.machines,
      now: Date.now
    })

    setOffline(studio.id, true)
    const child = await startedSession(
      remote,
      await home.machines.invoke(
        laptop.id,
        "codevisor.agents.start",
        startArgs("status"),
        parentOrigin
      )
    )
    await waitFor(async () => (await run(remote.services.db.listFleetMessages)).length === 1)
    await outbox.flush()
    const stillQueued = await run(remote.services.db.listFleetMessages)
    setOffline(studio.id, false)
    await outbox.flush()
    await outbox.flush()

    expect(stillQueued).toHaveLength(1)
    expect(await run(remote.services.db.listFleetMessages)).toEqual([])
    await waitFor(() => promptsMatching(home, turnEndedFor(child.id)) > 0)
    expect(promptsMatching(home, turnEndedFor(child.id))).toBe(1)
  })
})

describe("events from another machine", () => {
  it("wake the named chat once, even when the same event is delivered again", async () => {
    const { home, parent } = await startFleet()
    const event = {
      sessionId: parent.id,
      deliveryId: "d-once",
      text: "<codevisor-event>once</codevisor-event>"
    }

    const first = await invokeAs(laptop, home, eventBody(event))
    await waitFor(() => promptsMatching(home, "once") > 0)
    const again = await invokeAs(laptop, home, eventBody(event))

    expect([resultOf(first.body), resultOf(again.body)]).toEqual([
      { delivered: true },
      { delivered: false }
    ])
    expect(promptsMatching(home, "once")).toBe(1)
  })

  it("are refused for an archived chat so the sender stops retrying", async () => {
    const { home, parent } = await startFleet()
    await run(home.services.db.updateWorkspace(parent.workspaceId!, { isArchived: true }))
    const event = { sessionId: parent.id, deliveryId: "d-a", text: "t" }

    const answer = await invokeAs(laptop, home, eventBody(event))

    expect(answer.status).toBe(409)
  })

  it("are refused when unverified, replayed, misaddressed, or malformed", async () => {
    const { home, parent } = await startFleet()
    const event = { sessionId: parent.id, deliveryId: "d", text: "t" }
    const replayed = home.fleetTickets.callers.issue({
      deviceId: laptop.id,
      publicKey: laptop.publicKey
    })
    const replay = () =>
      postInvoke(home.server.url, eventBody({ ...event, sessionId: "nobody" }), {
        [FLEET_CALLER_HEADER]: replayed
      })

    const unverified = await postInvoke(home.server.url, eventBody(event))
    const firstUse = await replay()
    const secondUse = await replay()
    const malformed = await Promise.all(
      [
        "not an event",
        { sessionId: parent.id },
        { ...event, deliveryId: 4 },
        { ...event, text: 4 }
      ].map((args) => invokeAs(laptop, home, eventBody(args)))
    )

    expect([unverified.status, firstUse.status, secondUse.status]).toEqual([403, 404, 403])
    expect(malformed.map((answer) => answer.status)).toEqual([400, 400, 400, 400])
  })
})

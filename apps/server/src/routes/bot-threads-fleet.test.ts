import { decode, Thread, type MachineCallOrigin } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { jsonRequest, run, waitFor } from "../test-support.js"
import { field } from "../unknown-values.js"
import { createBot, decodeBot } from "./bot-test-support.js"
import {
  invokeAs,
  laptop,
  post,
  startFleet,
  stranger,
  studio,
  type FleetMachine
} from "./fleet-test-support.js"

const ThreadMessagePage = Schema.Struct({
  messages: Schema.Array(Schema.Struct({ text: Schema.String, from: Schema.Unknown })),
  hasMore: Schema.Boolean
})

const addBot = async (machine: FleetMachine, name: string) =>
  decodeBot((await createBot(machine, { name, projectIds: [] })).body)

const startBots = async () => {
  const fleet = await startFleet()
  const release = await addBot(fleet.home, "Release")
  const triage = await addBot(fleet.remote, "Triage")
  const releaseOrigin: MachineCallOrigin = {
    machineId: studio.id,
    machineName: studio.name,
    sessionId: release.sessionId,
    sessionTitle: "Release",
    botId: release.id
  }
  return { ...fleet, release, triage, releaseOrigin }
}

const threadsOf = async (machine: FleetMachine, botId: string) =>
  decode(Schema.Array(Thread))(
    (await jsonRequest(machine.server, `/v1/bots/${botId}/threads`)).body
  )

const textsIn = async (machine: FleetMachine, threadId: string) =>
  decode(ThreadMessagePage)(
    (await jsonRequest(machine.server, `/v1/threads/${threadId}/messages`)).body
  ).messages.map((message) => message.text)

const delivered = async (machine: FleetMachine, text: string): Promise<unknown> => {
  const carries = ([, input]: ReadonlyArray<unknown>) =>
    typeof input === "string" && input.includes(text)
  await waitFor(() => machine.agents.prompts.some(carries))
  return machine.agents.prompts.find(carries)?.[1]
}

describe("bot threads across machines", () => {
  it("carries a thread between bots on two machines, with a copy on each", async () => {
    const { home, remote, release, triage, releaseOrigin } = await startBots()

    const sent = await home.machines.invoke(
      laptop.id,
      "codevisor.bots.message",
      { botId: triage.id, text: "Is the build green?" },
      releaseOrigin
    )
    const threadId = String(field(sent, "threadId"))

    expect(await delivered(remote, "Is the build green?")).toBe(
      `<codevisor-event type="thread.message" threadId="${threadId}" from="bot" botId="${release.id}" machineId="${studio.id}" name="Release">\nIs the build green?\n</codevisor-event>`
    )
    await waitFor(async () => (await threadsOf(home, release.id)).length === 1)
    expect(await threadsOf(home, release.id)).toMatchObject([
      {
        threadId,
        participants: [
          { kind: "bot", name: "Release", botId: release.id },
          { kind: "bot", name: "Triage", botId: triage.id, machineId: laptop.id }
        ]
      }
    ])
    expect(await threadsOf(remote, triage.id)).toMatchObject([
      {
        threadId,
        participants: [
          { kind: "bot", name: "Release", botId: release.id, machineId: studio.id },
          { kind: "bot", name: "Triage", botId: triage.id }
        ]
      }
    ])

    await post(remote, `/v1/sessions/${triage.sessionId}/messages`, { text: "Yes.", threadId })

    expect(await delivered(home, "Yes.")).toBe(
      `<codevisor-event type="thread.message" threadId="${threadId}" from="bot" botId="${triage.id}" machineId="${laptop.id}" name="Triage">\nYes.\n</codevisor-event>`
    )

    await post(home, `/v1/sessions/${release.sessionId}/messages`, { text: "Shipping.", threadId })

    expect(await delivered(remote, "Shipping.")).toContain(`botId="${release.id}"`)
    await waitFor(async () => (await textsIn(home, threadId)).length === 3)
    expect(await textsIn(home, threadId)).toEqual(["Is the build green?", "Yes.", "Shipping."])
    expect(await textsIn(remote, threadId)).toEqual(["Is the build green?", "Yes.", "Shipping."])
    expect(
      home.agents.prompts.filter(
        ([, input]) => typeof input === "string" && input.includes("Is the build green?")
      )
    ).toEqual([])
  })

  it("lets an agent on another machine message a bot and hear back", async () => {
    const { home, remote, triage, parent, parentOrigin } = await startBots()

    await home.machines.invoke(
      laptop.id,
      "codevisor.bots.message",
      { botId: triage.id, text: "Login is fixed." },
      { ...parentOrigin, sessionTitle: "Fix login" }
    )
    const [thread] = await threadsOf(remote, triage.id)

    expect(thread?.participants[0]).toEqual({
      kind: "agent",
      name: "Fix login",
      agentId: parent.id,
      machineId: studio.id
    })
    expect(await delivered(remote, "Login is fixed.")).toContain(
      `from="agent" agentId="${parent.id}" machineId="${studio.id}" name="Fix login"`
    )

    await post(remote, `/v1/sessions/${triage.sessionId}/messages`, {
      text: "Thanks.",
      threadId: thread?.threadId
    })

    expect(await delivered(home, "Thanks.")).toContain(
      `from="bot" botId="${triage.id}" machineId="${laptop.id}" name="Triage"`
    )
    expect(await threadsOf(home, triage.id).catch(() => [])).toEqual([])
  })

  it("names a bot on another machine Bot when its machine sent no name, and queues a reply it cannot send yet", async () => {
    const { home, remote, release, triage, releaseOrigin, setOffline } = await startBots()
    const { sessionTitle: _, ...unnamed } = releaseOrigin
    await home.machines.invoke(
      laptop.id,
      "codevisor.bots.message",
      { botId: triage.id, text: "Hello" },
      unnamed
    )
    const [thread] = await threadsOf(remote, triage.id)
    await waitFor(async () => (await threadsOf(home, release.id)).length === 1)
    setOffline(studio.id, true)

    await post(remote, `/v1/sessions/${triage.sessionId}/messages`, {
      text: "Are you there?",
      threadId: thread?.threadId
    })

    expect(thread?.participants[0]).toMatchObject({ name: "Bot", botId: release.id })
    await waitFor(async () => (await run(remote.services.db.listFleetMessages)).length === 1)
    expect((await run(remote.services.db.listFleetMessages))[0]).toMatchObject({
      machineId: studio.id,
      path: "fleet.thread_message",
      origin: { machineId: laptop.id }
    })
    expect(await textsIn(home, String(thread?.threadId))).toEqual(["Hello"])
  })

  it("takes a thread message only from the machine it names, for a bot that is here", async () => {
    const { home, remote, release, triage } = await startBots()
    const participants = [
      {
        kind: "bot",
        name: "Release",
        agentId: release.sessionId,
        botId: release.id,
        machineId: studio.id
      },
      {
        kind: "bot",
        name: "Triage",
        agentId: triage.sessionId,
        botId: triage.id,
        machineId: laptop.id
      }
    ]
    const message = {
      id: "m1",
      threadId: "t1",
      sequence: 1,
      from: participants[0],
      text: "Hello",
      createdAt: "2026-11-12T00:00:00.000Z"
    }
    const call = (caller: typeof studio, args: unknown) =>
      invokeAs(caller, remote, {
        path: "fleet.thread_message",
        args,
        origin: { machineId: caller.id, machineName: caller.name }
      })
    const args = { threadId: "t1", participants, message }

    const forged = await call(stranger, args)
    const malformed = await call(studio, { threadId: "t1" })
    const refusal = async (changed: ReadonlyArray<unknown>) => {
      const answer = await call(studio, { ...args, participants: changed })
      return [answer.status, field(field(answer.body, "error"), "message")]
    }
    const notBetweenBots = [404, "That thread is not between a bot here and a bot there"]
    const [fromStudio, onLaptop] = participants
    const { botId: _, ...agentOnLaptop } = { ...onLaptop }
    const { botId: __, ...agentOnStudio } = { ...fromStudio }
    const first = await call(studio, args)
    const repeated = await call(studio, args)

    expect(forged.status).not.toBe(200)
    expect([malformed.status, field(field(malformed.body, "error"), "message")]).toEqual([
      400,
      "Expected { threadId, participants, message }"
    ])
    expect(await refusal([fromStudio, { ...onLaptop, botId: "missing" }])).toEqual(notBetweenBots)
    expect(await refusal([fromStudio, agentOnLaptop])).toEqual(notBetweenBots)
    expect(await refusal([fromStudio, { ...onLaptop, machineId: studio.id }])).toEqual(
      notBetweenBots
    )
    expect(await refusal([agentOnStudio, onLaptop])).toEqual(notBetweenBots)
    expect(await refusal([{ ...fromStudio, machineId: stranger.id }, onLaptop])).toEqual(
      notBetweenBots
    )
    expect([first.body, repeated.body]).toEqual([
      { result: { delivered: true } },
      { result: { delivered: false } }
    ])
    expect(await textsIn(remote, "t1")).toEqual(["Hello"])
    expect(home.agents.prompts).toEqual([])
  })
})

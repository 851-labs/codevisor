import {
  decode,
  FLEET_CALLER_HEADER,
  FLEET_SESSION_EVENT_PATH,
  SessionSummary
} from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { makeFleetOutbox } from "../infra/fleet-outbox.js"
import { run, waitFor } from "../test-support.js"
import {
  createArgs,
  createdSession,
  invokeAs,
  laptop,
  post,
  postInvoke,
  resultOf,
  startFleet,
  studio,
  type FleetMachine
} from "./fleet-test-support.js"
import { sendFinishedFleetTurns } from "./fleet-turns.js"

const origin = { machineId: laptop.id, machineName: laptop.name, sessionId: "child-1" }

const eventBody = (args: unknown) => ({ path: FLEET_SESSION_EVENT_PATH, args, origin })

const promptsMatching = (machine: FleetMachine, text: string) =>
  machine.agents.prompts.filter(([, input]) => typeof input === "string" && input.includes(text))
    .length

const turnEndedFor = (sessionId: string) => `type="session.turn_ended" sessionId="${sessionId}"`

describe("fleet session events", () => {
  it("wakes only the bot named in the event, in that bot's own chat", async () => {
    const { home, bot } = await startFleet()
    const plain = decode(SessionSummary)(
      (await post(home, "/v1/sessions", { projectId: "bot-project", harnessId: "codex" })).body
    )
    const event = {
      sessionId: bot.sessionId,
      botId: bot.id,
      deliveryId: "d-1",
      key: "k",
      text: "<codevisor-event/>"
    }

    const otherBot = await invokeAs(laptop, home, eventBody({ ...event, botId: plain.id }))
    const notTheBotsChat = await invokeAs(
      laptop,
      home,
      eventBody({ ...event, sessionId: plain.id })
    )
    const delivered = await invokeAs(laptop, home, eventBody(event))

    expect([otherBot.status, notTheBotsChat.status, delivered.status]).toEqual([403, 403, 200])
    await waitFor(() => promptsMatching(home, "<codevisor-event/>") > 0)
  })

  it("wakes the bot once when the same event is delivered again", async () => {
    const { home, bot } = await startFleet()
    const event = {
      sessionId: bot.sessionId,
      botId: bot.id,
      deliveryId: "d-once",
      key: "k",
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

  it("keeps a completion for an offline bot machine and delivers it once it is back", async () => {
    const { home, remote, botOrigin, setOffline } = await startFleet()
    const child = createdSession(
      await home.machines.invoke(laptop.id, "codevisor.sessions.create", createArgs, botOrigin)
    )
    const outbox = makeFleetOutbox({
      db: remote.services.db,
      machines: remote.machines,
      now: Date.now
    })

    setOffline(studio.id, true)
    await post(remote, `/v1/sessions/${child.id}/prompt`, { text: "status" })
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

  it("sends a finished turn the server never got to forward, once, when it next runs", async () => {
    const { home, remote, botOrigin } = await startFleet()
    const child = createdSession(
      await home.machines.invoke(laptop.id, "codevisor.sessions.create", createArgs, botOrigin)
    )
    const sender = {
      serverId: laptop.id,
      fleet: {
        machines: remote.machines,
        outbox: makeFleetOutbox({
          db: remote.services.db,
          machines: remote.machines,
          now: Date.now
        })
      }
    }

    await run(
      remote.services.db.appendEvent("session.updated", child.id, {
        turnState: "ended",
        stopReason: "end_turn"
      })
    )
    const pendingBeforeRestart = await run(remote.services.db.listFleetPendingTurns)
    await sendFinishedFleetTurns(remote.services, sender)
    await sendFinishedFleetTurns(remote.services, sender)

    expect(pendingBeforeRestart).toHaveLength(1)
    expect(await run(remote.services.db.listFleetMessages)).toEqual([])
    await waitFor(() => promptsMatching(home, turnEndedFor(child.id)) > 0)
    expect(promptsMatching(home, turnEndedFor(child.id))).toBe(1)
  })

  it("refuses events for an archived bot so the sender stops retrying", async () => {
    const { home, bot } = await startFleet()
    await run(home.services.db.updateWorkspace(bot.workspaceId, { isArchived: true }))
    const event = { sessionId: bot.sessionId, botId: bot.id, deliveryId: "d-a", text: "t" }

    const answer = await invokeAs(laptop, home, eventBody(event))

    expect(answer.status).toBe(409)
  })

  it("refuses unverified, replayed, misaddressed, and malformed events", async () => {
    const { home, bot } = await startFleet()
    const event = { sessionId: bot.sessionId, botId: bot.id, deliveryId: "d", key: "k", text: "t" }
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
        { sessionId: bot.sessionId },
        { ...event, botId: 4 },
        { ...event, deliveryId: 4 },
        { ...event, text: 4 }
      ].map((args) => invokeAs(laptop, home, eventBody(args)))
    )

    expect([unverified.status, firstUse.status, secondUse.status]).toEqual([403, 404, 403])
    expect(malformed.map((answer) => answer.status)).toEqual([400, 400, 400, 400, 400])
  })
})

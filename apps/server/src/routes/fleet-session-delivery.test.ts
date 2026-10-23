import {
  decode,
  FLEET_CALLER_HEADER,
  FLEET_SESSION_EVENT_PATH,
  SessionSummary
} from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { waitFor } from "../test-support.js"
import { invokeAs, laptop, post, postInvoke, startFleet } from "./fleet-test-support.js"

const origin = { machineId: laptop.id, machineName: laptop.name, sessionId: "child-1" }

const eventBody = (args: unknown) => ({ path: FLEET_SESSION_EVENT_PATH, args, origin })

describe("fleet session events", () => {
  it("wakes only the bot named in the event, in that bot's own chat", async () => {
    const { home, bot } = await startFleet()
    const plain = decode(SessionSummary)(
      (await post(home, "/v1/sessions", { projectId: "bot-project", harnessId: "codex" })).body
    )
    const event = { sessionId: bot.sessionId, botId: bot.id, key: "k", text: "<codevisor-event/>" }

    const otherBot = await invokeAs(laptop, home, eventBody({ ...event, botId: plain.id }))
    const notTheBotsChat = await invokeAs(
      laptop,
      home,
      eventBody({ ...event, sessionId: plain.id })
    )
    const delivered = await invokeAs(laptop, home, eventBody(event))

    expect([otherBot.status, notTheBotsChat.status, delivered.status]).toEqual([403, 403, 200])
    await waitFor(() => home.agents.prompts.some(([, input]) => input === "<codevisor-event/>"))
  })

  it("refuses unverified, replayed, misaddressed, and malformed events", async () => {
    const { home, bot } = await startFleet()
    const event = { sessionId: bot.sessionId, botId: bot.id, key: "k", text: "t" }
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
        { ...event, text: 4 }
      ].map((args) => invokeAs(laptop, home, eventBody(args)))
    )

    expect([unverified.status, firstUse.status, secondUse.status]).toEqual([403, 404, 403])
    expect(malformed.map((answer) => answer.status)).toEqual([400, 400, 400, 400])
  })
})

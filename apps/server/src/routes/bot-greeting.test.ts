import { BotConversationPage, decode } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { jsonRequest, run, waitFor } from "../test-support.js"
import { decodeBot, endedTurns, postBot, setUp, type Running } from "./bot-test-support.js"

const decodePage = decode(BotConversationPage)

const promptTexts = (running: Running): ReadonlyArray<string> =>
  running.agents.prompts.map(([, input]) => (typeof input === "string" ? input : input.text))

const createAndHearHello = async (running: Running, body: Record<string, unknown>) => {
  const response = await postBot(running, body)
  const bot = decodeBot(response.body)
  await waitFor(() => endedTurns(running, bot.sessionId) === 1)
  return bot
}

describe("a new bot's hello", () => {
  it("starts a new bot's first turn with a hidden event that asks it to introduce itself", async () => {
    const running = await setUp()

    const bot = await createAndHearHello(running, { name: "Bob", projectIds: [] })

    expect(promptTexts(running)).toEqual([
      '<codevisor-event type="bot.created">\n' +
        "The user just created you and hasn't written to you yet. Introduce yourself now: send a " +
        "short hello, then a second message that asks what they'd like you to do.\n" +
        "</codevisor-event>"
    ])
    const page = decodePage(
      (await jsonRequest(running.server, `/v1/sessions/${bot.sessionId}/conversation`)).body
    )
    expect(page.messages).toEqual([])
  })

  it("says hello once when the same bot is created twice", async () => {
    const running = await setUp()
    const bot = await createAndHearHello(running, { id: "bot-1", name: "Bob", projectIds: [] })

    const repeated = await postBot(running, { id: "bot-1", name: "Bob", projectIds: [] })

    expect(repeated.status).toBe(200)
    expect(await run(running.services.db.listPromptQueue(bot.sessionId))).toEqual([])
    expect(promptTexts(running)).toHaveLength(1)
  })
})

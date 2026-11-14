import { readFileSync } from "node:fs"
import { join } from "node:path"

import { FLEET_BOTS_PATH, type Bot } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { jsonRequest } from "../test-support.js"
import { createBot, decodeBot, listBots, setUp, type Running } from "./bot-test-support.js"
import { invokeAs, laptop, postInvoke, resultOf, startFleet } from "./fleet-test-support.js"
import { idOf } from "./response-test-support.js"

const instructions = (bot: Bot): string => readFileSync(join(bot.rootPath, "AGENTS.md"), "utf8")

const newBot = async (running: Pick<Running, "server">, name: string): Promise<Bot> =>
  decodeBot((await createBot(running, { name, projectIds: [] })).body)

const sayWhatItDoes = (running: Pick<Running, "server">, chatId: string, about: string) =>
  jsonRequest(running.server, `/v1/sessions/${chatId}/bot/about`, {
    body: JSON.stringify({ about }),
    method: "PUT"
  })

describe("what bots know about each other", () => {
  it("lists a bot's own words about what it does to the user's other bots, without waking them", async () => {
    const running = await setUp()
    const macro = await newBot(running, "Macro")
    const bigBoi = await newBot(running, "Big Boi")
    const promptsBefore = running.agents.prompts.length

    const described = await sayWhatItDoes(
      running,
      macro.sessionId,
      "  Logs meals and\ntracks nutrition. "
    )

    expect(decodeBot(described.body).about).toBe("Logs meals and tracks nutrition.")
    expect((await listBots(running)).map((bot) => [bot.name, bot.about])).toEqual([
      ["Macro", "Logs meals and tracks nutrition."],
      ["Big Boi", undefined]
    ])
    expect(instructions(bigBoi)).toContain(
      `- Macro (botId \`${macro.id}\`): Logs meals and tracks nutrition.`
    )
    expect(instructions(macro)).toContain('Yours says: "Logs meals and tracks nutrition."')
    expect(instructions(macro)).toContain(
      `- Big Boi (botId \`${bigBoi.id}\`): hasn't said what it does yet`
    )
    expect(running.agents.prompts.length).toBe(promptsBefore)
  })

  it("lets only a bot's own chat say what it does, in a few words", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const macro = await newBot(running, "Macro")
    const chat = await jsonRequest(running.server, "/v1/sessions", {
      body: JSON.stringify({ projectId: "api-project", harnessId: "codex" }),
      method: "POST"
    })
    const chatId = idOf(chat.body)

    const fromAnotherChat = await sayWhatItDoes(running, chatId, "Does everything.")
    const tooLong = await sayWhatItDoes(running, macro.sessionId, "x".repeat(301))

    expect([fromAnotherChat.status, tooLong.status]).toEqual([403, 422])
    expect((await listBots(running))[0]?.about).toBeUndefined()
  })

  it("lists the bots another machine says it has, and drops the ones it no longer has", async () => {
    const { home } = await startFleet()
    const bigBoi = await newBot(home, "Big Boi")
    const origin = { machineId: laptop.id, machineName: laptop.name }
    const roster = (bots: unknown) => ({ path: FLEET_BOTS_PATH, args: { bots }, origin })

    const first = await invokeAs(
      laptop,
      home,
      roster([
        { botId: "bot-macro", name: "Macro", about: "Logs meals." },
        { botId: "bot-buff", name: "Buff" }
      ])
    )
    const listedBoth = instructions(bigBoi)
    await invokeAs(laptop, home, roster([{ botId: "bot-buff", name: "Buff" }]))
    const unverified = await postInvoke(home.server.url, roster([]))
    const malformed = await invokeAs(laptop, home, roster([{ name: "No id" }]))

    expect(resultOf(first.body)).toEqual({ bots: 2 })
    expect(listedBoth).toContain("- Macro (botId `bot-macro`, on machine `Laptop`): Logs meals.")
    expect(instructions(bigBoi)).not.toContain("bot-macro")
    expect(instructions(bigBoi)).toContain(
      "- Buff (botId `bot-buff`, on machine `Laptop`): hasn't said what it does yet"
    )
    expect([unverified.status, malformed.status]).toEqual([403, 400])
  })
})

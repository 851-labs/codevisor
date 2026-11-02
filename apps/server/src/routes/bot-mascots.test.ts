import { BotMascotOptions, decode } from "@codevisor/api"
import sharp from "sharp"
import { describe, expect, it } from "vitest"

import { jsonRequest } from "../test-support.js"
import { createBot, decodeBot, setUp, type Running } from "./bot-test-support.js"

const mascotOptions = async (running: Running) =>
  decode(BotMascotOptions)((await jsonRequest(running.server, "/v1/bot-mascots")).body)

const patchBot = (running: Running, id: string, body: Record<string, unknown>) =>
  jsonRequest(running.server, `/v1/bots/${id}`, { body: JSON.stringify(body), method: "PATCH" })

describe("bot mascot routes", () => {
  it("gives each new bot the next color unless one is chosen, and saves edits", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const chosen = { color: "sky", hat: "crown", eyewear: "monocle" }

    const options = await mascotOptions(running)
    const first = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)
    const second = decodeBot(
      (await createBot(running, { name: "Second", projectIds: ["api-project"], mascot: chosen }))
        .body
    )

    expect(options.hats[0]).toEqual({ id: "none", title: "None" })
    expect(options.eyewear.map((item) => item.id)).toContain("monocle")
    expect(options.nextBotMascot).toEqual({ color: "sunny", hat: "none", eyewear: "none" })
    expect(first.mascot).toEqual(options.nextBotMascot)
    expect(second.mascot).toEqual(chosen)
    expect((await mascotOptions(running)).nextBotMascot.color).toBe("lilac")
    const edited = await patchBot(running, first.id, { mascot: chosen })
    expect(decodeBot(edited.body).mascot).toEqual(chosen)
    expect(decodeBot((await patchBot(running, first.id, { name: "Renamed" })).body).mascot).toEqual(
      chosen
    )
  })

  it("refuses a mascot item the package doesn't draw", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)
    const unknownHat = { color: "mint", hat: "fez", eyewear: "none" }

    expect((await patchBot(running, bot.id, { mascot: unknownHat })).status).toBe(422)
    expect(
      (await createBot(running, { projectIds: ["api-project"], mascot: unknownHat })).status
    ).toBe(422)
    expect(
      decodeBot((await jsonRequest(running.server, `/v1/bots/${bot.id}`)).body).mascot
    ).toEqual(bot.mascot)
  })

  it("draws a mascot as a square PNG", async () => {
    const running = await setUp()

    const image = await fetch(
      `${running.server.url}/v1/bot-mascots/image?color=mint&hat=beanie&eyewear=specs`
    )
    const missing = await fetch(`${running.server.url}/v1/bot-mascots/image?color=plaid`)

    expect(image.headers.get("content-type")).toBe("image/png")
    expect(await sharp(Buffer.from(await image.arrayBuffer())).metadata()).toMatchObject({
      format: "png",
      width: 256,
      height: 256
    })
    expect(missing.status).toBe(400)
  })
})

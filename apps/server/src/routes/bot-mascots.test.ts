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
    const chosen = {
      color: "sky",
      hat: "beanie",
      hatColor: "red",
      eyewear: "goggles",
      eyewearColor: "auto"
    }

    const options = await mascotOptions(running)
    const first = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)
    const second = decodeBot(
      (await createBot(running, { name: "Second", projectIds: ["api-project"], mascot: chosen }))
        .body
    )

    expect(options.hats[0]).toEqual({ id: "none", title: "None" })
    expect(options.hats.find((hat) => hat.id === "crown")).toEqual({ id: "crown", title: "Crown" })
    expect(options.hats.find((hat) => hat.id === "beanie")).toMatchObject({
      hasAuto: true,
      swatches: expect.arrayContaining([{ id: "red", title: "Red", hex: "#E5484D" }])
    })
    expect(options.colors.find((color) => color.id === "sunny")?.accent).toBe("#4F7BFF")
    expect(options.eyewear.map((item) => item.id)).toContain("monocle")
    expect(options.nextBotMascot).toEqual({
      color: "sunny",
      hat: "none",
      hatColor: "auto",
      eyewear: "none",
      eyewearColor: "auto"
    })
    expect(first.mascot).toEqual(options.nextBotMascot)
    expect(second.mascot).toEqual(chosen)
    expect((await mascotOptions(running)).nextBotMascot.color).toBe("lilac")
    const edited = await patchBot(running, first.id, { mascot: chosen })
    expect(decodeBot(edited.body).mascot).toEqual(chosen)
    expect(decodeBot((await patchBot(running, first.id, { name: "Renamed" })).body).mascot).toEqual(
      chosen
    )
  })

  it.each([
    ["an item the package doesn't draw", { color: "mint", hat: "fez", eyewear: "none" }],
    [
      "a color the hat doesn't offer",
      { color: "mint", hat: "crown", hatColor: "red", eyewear: "none" }
    ],
    ["a color for no eyewear", { color: "mint", hat: "none", eyewear: "none", eyewearColor: "red" }]
  ])("refuses a mascot with %s", async (_case, mascot) => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)

    expect((await patchBot(running, bot.id, { mascot })).status).toBe(422)
    expect((await createBot(running, { projectIds: ["api-project"], mascot })).status).toBe(422)
    expect(
      decodeBot((await jsonRequest(running.server, `/v1/bots/${bot.id}`)).body).mascot
    ).toEqual(bot.mascot)
  })

  it("draws a mascot as a square PNG", async () => {
    const running = await setUp()

    const image = await fetch(
      `${running.server.url}/v1/bot-mascots/image?color=mint&hat=beanie&eyewear=specs`
    )
    const missing = await fetch(`${running.server.url}/v1/bot-mascots/image?color=mint&hat=fez`)

    expect(image.headers.get("content-type")).toBe("image/png")
    expect(await sharp(Buffer.from(await image.arrayBuffer())).metadata()).toMatchObject({
      format: "png",
      width: 384,
      height: 384
    })
    expect(missing.status).toBe(400)
  })

  it("draws a mascot's idle loop as an animated WebP and refuses an unknown loop", async () => {
    const running = await setUp()
    const query = "color=mint&hat=wizard&eyewear=goggles"

    const idle = await fetch(`${running.server.url}/v1/bot-mascots/animation?${query}&loop=idle`)
    const unknown = await fetch(
      `${running.server.url}/v1/bot-mascots/animation?${query}&loop=dance`
    )

    expect(idle.headers.get("content-type")).toBe("image/webp")
    expect(await sharp(Buffer.from(await idle.arrayBuffer())).metadata()).toMatchObject({
      format: "webp",
      pages: 120,
      loop: 0
    })
    expect(unknown.status).toBe(400)
  })

  it("serves the Rive file and a mascot's values for it", async () => {
    const running = await setUp()
    const query = "color=mint&hat=wizard&eyewear=goggles"

    const file = await fetch(`${running.server.url}/v1/bot-mascots/rive`)
    const etag = file.headers.get("etag") ?? ""
    const unchanged = await fetch(`${running.server.url}/v1/bot-mascots/rive`, {
      headers: { "If-None-Match": etag }
    })
    const values = await jsonRequest(running.server, `/v1/bot-mascots/rive-values?${query}`)
    const teal = await jsonRequest(
      running.server,
      `/v1/bot-mascots/rive-values?${query}&hatColor=teal`
    )
    const missing = await fetch(
      `${running.server.url}/v1/bot-mascots/rive-values?color=mint&hat=fez`
    )

    expect(file.headers.get("content-type")).toBe("application/octet-stream")
    expect(file.headers.get("cache-control")).toBe("private, no-cache")
    expect(etag).not.toBe("")
    expect(unchanged.status).toBe(304)
    expect(
      Buffer.from(await file.arrayBuffer())
        .subarray(0, 4)
        .toString()
    ).toBe("RIVE")
    expect(values.body).toMatchObject({
      hat: "wizard",
      "face/eyewear": "goggles",
      body0: expect.any(String)
    })
    expect(teal.body).toMatchObject({ hat: "wizard" })
    expect(teal.body).not.toEqual(values.body)
    expect(missing.status).toBe(400)
  })

  it("draws a color it doesn't know as the default color", async () => {
    const running = await setUp()
    const valuesFor = async (color: string) =>
      (await jsonRequest(running.server, `/v1/bot-mascots/rive-values?color=${color}`)).body

    expect(await valuesFor("plaid")).toEqual(await valuesFor("sunny"))
    expect(await valuesFor("grape")).not.toEqual(await valuesFor("sunny"))
  })
})

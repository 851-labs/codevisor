import type { IncomingMessage, ServerResponse } from "node:http"

import type {
  BotMascot,
  BotMascotChoice,
  BotMascotColorChoice,
  BotMascotOptions
} from "@codevisor/api"
import {
  botMascotColors,
  botMascotEyewear,
  botMascotHats,
  renderBotMascotSvg,
  type BotMascotConfig,
  type ColorOption,
  type ItemOption
} from "@codevisor/bot-mascot"
import sharp from "sharp"

import { HttpFailure, run, writeJson, type CodevisorServerServices } from "../server-context.js"

const imagePixels = 256
const none: BotMascotChoice = { id: "none", title: "None" }

export const routeBotMascots = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (request.method !== "GET") return false
  if (url.pathname === "/v1/bot-mascots") {
    writeJson(response, 200, await mascotOptions(services))
    return true
  }
  if (url.pathname !== "/v1/bot-mascots/image") return false

  const mascot = mascotFromQuery(url.searchParams)
  const config = mascotConfig(mascot)
  if (config === undefined) throw unknownMascot(400, mascot)

  const png = await renderPng(config)
  response.writeHead(200, {
    "Cache-Control": "private, max-age=31536000, immutable",
    "Content-Length": String(png.byteLength),
    "Content-Type": "image/png"
  })
  response.end(png)
  return true
}

export const assertBotMascot = (mascot: BotMascot): void => {
  if (mascotConfig(mascot) === undefined) throw unknownMascot(422, mascot)
}

export const newBotMascot = async (
  services: CodevisorServerServices,
  requested: BotMascot | undefined
): Promise<BotMascot> => {
  if (requested === undefined) return nextBotMascot(services)

  assertBotMascot(requested)
  return requested
}

const nextBotMascot = async (services: CodevisorServerServices): Promise<BotMascot> => {
  const botCount = (await run(services.db.listBots)).length
  const color = botMascotColors[botCount % botMascotColors.length]!
  return { color: color.id, hat: none.id, eyewear: none.id }
}

const mascotOptions = async (services: CodevisorServerServices): Promise<BotMascotOptions> => ({
  colors: botMascotColors.map(colorChoice),
  hats: [none, ...botMascotHats.map(choice)],
  eyewear: [none, ...botMascotEyewear.map(choice)],
  nextBotMascot: await nextBotMascot(services)
})

const colorChoice = (color: ColorOption): BotMascotColorChoice => ({
  id: color.id,
  title: color.title,
  gradient: color.gradient.map(([, hex]) => hex)
})

const choice = ({ id, title }: ItemOption<string>): BotMascotChoice => ({ id, title })

const mascotConfig = (mascot: BotMascot): BotMascotConfig | undefined => {
  const color = botMascotColors.find((option) => option.id === mascot.color)?.id
  const hat = itemId(botMascotHats, mascot.hat)
  const eyewear = itemId(botMascotEyewear, mascot.eyewear)
  if (color === undefined || hat === undefined || eyewear === undefined) return undefined
  return { color, hat, eyewear }
}

const itemId = <Id extends string>(
  items: ReadonlyArray<ItemOption<Id>>,
  id: string
): Id | "none" | undefined => {
  if (id === none.id) return "none"
  return items.find((item) => item.id === id)?.id
}

const mascotFromQuery = (query: URLSearchParams): BotMascot => ({
  color: query.get("color") ?? "",
  hat: query.get("hat") ?? none.id,
  eyewear: query.get("eyewear") ?? none.id
})

const unknownMascot = (status: number, mascot: BotMascot): HttpFailure =>
  new HttpFailure(status, `Unknown bot mascot: ${JSON.stringify(mascot)}`)

const renderPng = async (config: BotMascotConfig): Promise<Buffer> => {
  const svg = renderBotMascotSvg({ ...config, size: imagePixels })
  return sharp(Buffer.from(svg)).png({ compressionLevel: 9 }).toBuffer()
}

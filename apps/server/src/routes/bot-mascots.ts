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
  type BotMascotConfig,
  type ColorOption,
  type ItemOption
} from "@codevisor/bot-mascot"

import { HttpFailure, run, writeJson, type CodevisorServerServices } from "../server-context.js"
import {
  mascotFramings,
  mascotLoops,
  renderMascotLoop,
  renderMascotStill,
  type MascotArt
} from "./bot-mascot-art.js"
import { mascotRiveFile, mascotRiveValues } from "./bot-mascot-rive.js"

type ArtRenderer = (config: BotMascotConfig, query: URLSearchParams) => Promise<MascotArt>

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
  if (url.pathname === "/v1/bot-mascots/rive") {
    writeArt(response, await mascotRiveFile())
    return true
  }
  if (url.pathname === "/v1/bot-mascots/rive-values") {
    writeJson(response, 200, mascotRiveValues(requiredConfig(url.searchParams)))
    return true
  }
  const render = artRenderers[url.pathname]
  if (render === undefined) return false

  writeArt(response, await render(requiredConfig(url.searchParams), url.searchParams))
  return true
}

const requiredConfig = (query: URLSearchParams): BotMascotConfig => {
  const mascot = mascotFromQuery(query)
  const config = mascotConfig(mascot)
  if (config === undefined) throw unknownMascot(400, mascot)
  return config
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

const artRenderers: Readonly<Record<string, ArtRenderer>> = {
  "/v1/bot-mascots/image": (config, query) =>
    renderMascotStill(config, queryChoice(query, "framing", mascotFramings)),
  "/v1/bot-mascots/animation": (config, query) =>
    renderMascotLoop(config, queryChoice(query, "loop", mascotLoops))
}

const queryChoice = <Choice extends string>(
  query: URLSearchParams,
  name: string,
  choices: ReadonlyArray<Choice>
): Choice => {
  const value = query.get(name) ?? choices[0]!
  const found = choices.find((option) => option === value)
  if (found === undefined) throw new HttpFailure(400, `Unknown ${name}: ${value}`)
  return found
}

const writeArt = (response: ServerResponse, art: MascotArt): void => {
  response.writeHead(200, {
    "Cache-Control": "private, max-age=31536000, immutable",
    "Content-Length": String(art.bytes.byteLength),
    "Content-Type": art.contentType
  })
  response.end(art.bytes)
}

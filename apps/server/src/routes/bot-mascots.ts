import type { IncomingMessage, ServerResponse } from "node:http"

import type {
  BotMascot,
  BotMascotChoice,
  BotMascotColorChoice,
  BotMascotOptions,
  BotMascotSwatch
} from "@codevisor/api"
import {
  botMascotColorRotation,
  botMascotColors,
  botMascotEyewear,
  botMascotHats,
  botMascotSwatches,
  defaultBotMascotConfig,
  type BotMascotConfig,
  type ColorOption,
  type ItemOption,
  type SwatchChoice
} from "@codevisor/bot-mascot"

import { HttpFailure, run, writeJson, type CodevisorServerServices } from "../server-context.js"
import {
  mascotFramings,
  mascotLoops,
  renderMascotLoop,
  renderMascotStill,
  type MascotArt
} from "./bot-mascot-art.js"
import { mascotRiveFile, mascotRiveValues, type RiveFile } from "./bot-mascot-rive.js"

type ArtRenderer = (config: BotMascotConfig, query: URLSearchParams) => Promise<MascotArt>

interface WornItem<Id extends string> {
  readonly id: Id | "none"
  readonly color: SwatchChoice
}

const none: BotMascotChoice = { id: "none", title: "None" }
const autoColor = "auto"

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
    writeRevalidated(request, response, await mascotRiveFile())
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
  const mascot = withKnownColor(mascotFromQuery(query))
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
  return {
    color: botMascotColorRotation[botCount % botMascotColorRotation.length]!,
    hat: none.id,
    hatColor: autoColor,
    eyewear: none.id,
    eyewearColor: autoColor
  }
}

const mascotOptions = async (services: CodevisorServerServices): Promise<BotMascotOptions> => ({
  colors: botMascotColors.map(colorChoice),
  hats: [none, ...botMascotHats.map(itemChoice)],
  eyewear: [none, ...botMascotEyewear.map(itemChoice)],
  nextBotMascot: await nextBotMascot(services)
})

const colorChoice = (color: ColorOption): BotMascotColorChoice => ({
  id: color.id,
  title: color.title,
  gradient: color.gradient.map(([, hex]) => hex),
  accent: color.accent
})

const itemChoice = (item: ItemOption<string>): BotMascotChoice => {
  if (item.swatches.length === 0) return { id: item.id, title: item.title }

  return {
    id: item.id,
    title: item.title,
    swatches: item.swatches.map(swatchChoice),
    hasAuto: item.hasAuto
  }
}

const swatchChoice = (id: string): BotMascotSwatch => ({
  id,
  title: id.charAt(0).toUpperCase() + id.slice(1),
  hex: botMascotSwatches.find((swatch) => swatch.id === id)!.hex
})

const withKnownColor = (mascot: BotMascot): BotMascot => {
  if (isKnownColor(mascot.color)) return mascot
  return { ...mascot, color: defaultBotMascotConfig.color }
}

const isKnownColor = (color: string): boolean =>
  botMascotColors.some((option) => option.id === color)

const mascotConfig = (mascot: BotMascot): BotMascotConfig | undefined => {
  const color = botMascotColors.find((option) => option.id === mascot.color)?.id
  const hat = wornItem(botMascotHats, mascot.hat, mascot.hatColor)
  const eyewear = wornItem(botMascotEyewear, mascot.eyewear, mascot.eyewearColor)
  if (color === undefined || hat === undefined || eyewear === undefined) return undefined
  return {
    color,
    hat: hat.id,
    hatColor: hat.color,
    eyewear: eyewear.id,
    eyewearColor: eyewear.color
  }
}

const wornItem = <Id extends string>(
  items: ReadonlyArray<ItemOption<Id>>,
  id: string,
  color: string = autoColor
): WornItem<Id> | undefined => {
  if (id === none.id) return color === autoColor ? { id: "none", color } : undefined

  const item = items.find((option) => option.id === id)
  const swatch = item && itemSwatch(item, color)
  if (item === undefined || swatch === undefined) return undefined
  return { id: item.id, color: swatch }
}

const itemSwatch = (item: ItemOption<string>, color: string): SwatchChoice | undefined => {
  if (color === autoColor) return autoColor
  return item.swatches.find((swatch) => swatch === color)
}

const mascotFromQuery = (query: URLSearchParams): BotMascot => ({
  color: query.get("color") ?? "",
  hat: query.get("hat") ?? none.id,
  hatColor: query.get("hatColor") ?? autoColor,
  eyewear: query.get("eyewear") ?? none.id,
  eyewearColor: query.get("eyewearColor") ?? autoColor
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

const writeRevalidated = (
  request: IncomingMessage,
  response: ServerResponse,
  file: RiveFile
): void => {
  if (request.headers["if-none-match"] !== file.etag) return writeFile(response, file)

  response.writeHead(304, revalidatedHeaders(file))
  response.end()
}

const writeFile = (response: ServerResponse, file: RiveFile): void => {
  response.writeHead(200, {
    ...revalidatedHeaders(file),
    "Content-Length": String(file.bytes.byteLength),
    "Content-Type": file.contentType
  })
  response.end(file.bytes)
}

const revalidatedHeaders = (file: RiveFile): Record<string, string> => ({
  "Cache-Control": "private, no-cache",
  ETag: file.etag
})

const writeArt = (response: ServerResponse, art: MascotArt): void => {
  response.writeHead(200, {
    "Cache-Control": "private, max-age=31536000, immutable",
    "Content-Length": String(art.bytes.byteLength),
    "Content-Type": art.contentType
  })
  response.end(art.bytes)
}

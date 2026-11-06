import { createServer } from "node:http"

import {
  mascotFramings,
  mascotLoops,
  renderMascotLoop,
  renderMascotStill
} from "../apps/server/src/routes/bot-mascot-art.ts"
import { mascotRiveFile, mascotRiveValues } from "../apps/server/src/routes/bot-mascot-rive.ts"
import {
  botMascotColors,
  botMascotEyewear,
  botMascotHats,
  botMascotSwatches
} from "../packages/bot-mascot/src/index.ts"

const none = { id: "none", title: "None" }

const routes = {
  "/v1/bot-mascots": () => json(mascotOptions()),
  "/v1/bot-mascots/image": (query) =>
    renderMascotStill(mascotConfig(query), choice(query, "framing", mascotFramings)),
  "/v1/bot-mascots/animation": (query) =>
    renderMascotLoop(mascotConfig(query), choice(query, "loop", mascotLoops)),
  "/v1/bot-mascots/rive": () => mascotRiveFile(),
  "/v1/bot-mascots/rive-values": (query) => json(mascotRiveValues(mascotConfig(query)))
}

const server = createServer(async (request, response) => {
  const url = new URL(request.url, "http://127.0.0.1")
  const route = routes[url.pathname]
  if (request.method !== "GET" || route === undefined) {
    response.writeHead(404).end()
    return
  }
  try {
    const art = await route(url.searchParams)
    response.writeHead(200, { "Content-Type": art.contentType }).end(art.bytes)
  } catch (error) {
    response.writeHead(400).end(String(error))
  }
})
server.listen(0, "127.0.0.1", () => {
  console.log(`http://127.0.0.1:${server.address().port}`)
})

function json(value) {
  return { contentType: "application/json", bytes: Buffer.from(JSON.stringify(value)) }
}

function mascotOptions() {
  return {
    colors: botMascotColors.map((color) => ({
      id: color.id,
      title: color.title,
      gradient: color.gradient.map(([, hex]) => hex),
      accent: color.accent
    })),
    hats: [none, ...botMascotHats.map(itemChoice)],
    eyewear: [none, ...botMascotEyewear.map(itemChoice)],
    nextBotMascot: {
      color: botMascotColors[0].id,
      hat: none.id,
      hatColor: "auto",
      eyewear: none.id,
      eyewearColor: "auto"
    }
  }
}

function itemChoice(item) {
  if (item.swatches.length === 0) return { id: item.id, title: item.title }
  return {
    id: item.id,
    title: item.title,
    hasAuto: item.hasAuto,
    swatches: item.swatches.map((id) => ({
      id,
      title: id.charAt(0).toUpperCase() + id.slice(1),
      hex: botMascotSwatches.find((swatch) => swatch.id === id).hex
    }))
  }
}

function mascotConfig(query) {
  return {
    color: query.get("color"),
    hat: query.get("hat") ?? "none",
    hatColor: query.get("hatColor") ?? "auto",
    eyewear: query.get("eyewear") ?? "none",
    eyewearColor: query.get("eyewearColor") ?? "auto"
  }
}

function choice(query, name, choices) {
  const value = query.get(name) ?? choices[0]
  if (!choices.includes(value)) throw new Error(`Unknown ${name}: ${value}`)
  return value
}

#!/usr/bin/env bun
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { createRequire } from "node:module"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

import { renderMascotStill } from "../apps/server/src/routes/bot-mascot-art.ts"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const catalog = join(
  root,
  "packages/swift/CodevisorUI/Sources/CodevisorUI/Resources/BotsEmptyCrew.xcassets"
)
const sharp = createRequire(join(root, "apps/server/package.json"))("sharp")
const crew = [
  { name: "bots-empty-crew-leader", mascot: { color: "sunny", hat: "crown", eyewear: "none" } },
  { name: "bots-empty-crew-left", mascot: { color: "mint", hat: "chef", eyewear: "none" } },
  { name: "bots-empty-crew-right", mascot: { color: "lilac", hat: "wizard", eyewear: "specs" } }
]
const info = { author: "xcode", version: 1 }
const channelTolerance = 8

const main = async () => {
  const figures = await Promise.all(crew.map(renderFigure))
  if (process.argv.includes("--check")) return checkCatalog(figures)

  writeCatalog(figures)
}

const renderFigure = async ({ name, mascot }) => ({
  name,
  bytes: (await renderMascotStill(mascot, "figure")).bytes
})

const writeCatalog = (figures) => {
  rmSync(catalog, { recursive: true, force: true })
  mkdirSync(catalog, { recursive: true })
  writeJson(join(catalog, "Contents.json"), { info })
  figures.forEach(writeImageSet)
}

const writeImageSet = ({ name, bytes }) => {
  mkdirSync(dirname(imagePath(name)), { recursive: true })
  writeFileSync(imagePath(name), bytes)
  writeJson(join(dirname(imagePath(name)), "Contents.json"), {
    images: [{ filename: `${name}.png`, idiom: "universal" }],
    info
  })
}

const checkCatalog = async (figures) => {
  const stale = (await Promise.all(figures.map(isStale))).some(Boolean)
  if (!stale) return

  console.error("Bundled Bots empty-state mascots are stale. Run `bun run mascots:export-crew`.")
  process.exitCode = 1
}

const isStale = async ({ name, bytes }) => {
  const bundled = await pixels(readFileSync(imagePath(name)))
  const rendered = await pixels(bytes)
  if (bundled.length !== rendered.length) return true
  return bundled.some((value, index) => Math.abs(value - rendered[index]) > channelTolerance)
}

const pixels = (png) => sharp(png).ensureAlpha().raw().toBuffer()

const imagePath = (name) => join(catalog, `${name}.imageset`, `${name}.png`)

const writeJson = (path, value) => writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`)

await main()

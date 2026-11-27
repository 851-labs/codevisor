#!/usr/bin/env bun
import { createHash } from "node:crypto"
import { mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

import { mascotRiveValues } from "../apps/server/src/routes/bot-mascot-rive.ts"
import { FIGURE_VIEW_BOX, portraitViewBox } from "../packages/bot-mascot/src/index.ts"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const mascotPackage = join(root, "packages/bot-mascot")
const bundled = join(root, "packages/swift/CodevisorUI/Sources/CodevisorUI/Resources/BotMascotArt")
const fixture = join(
  root,
  "packages/swift/CodevisorUI/Tests/CodevisorUITests/Fixtures/bot-mascot-rive-values.json"
)
const looks = [
  { color: "ruby", hat: "none", hatColor: "auto", eyewear: "none", eyewearColor: "auto" },
  { color: "sunny", hat: "crown", hatColor: "auto", eyewear: "specs", eyewearColor: "auto" },
  { color: "mint", hat: "beanie", hatColor: "teal", eyewear: "monocle", eyewearColor: "auto" },
  { color: "lilac", hat: "wizard", hatColor: "auto", eyewear: "goggles", eyewearColor: "pink" },
  { color: "tomato", hat: "propeller", hatColor: "auto", eyewear: "shades", eyewearColor: "auto" },
  { color: "clover", hat: "cowboy", hatColor: "auto", eyewear: "none", eyewearColor: "auto" }
]

const art = () => {
  const rive = readFileSync(join(mascotPackage, "resources/mascot.riv"))
  const colors = readFileSync(join(mascotPackage, "src/data/rive-colors.json"))
  const version = createHash("sha256").update(rive).update(colors).digest("hex").slice(0, 16)
  return {
    "mascot.riv": rive,
    "rive-colors.json": colors,
    version: Buffer.from(`${version}\n`),
    [fixture]: Buffer.from(`${JSON.stringify(appFixture(), null, 2)}\n`)
  }
}

const appFixture = () => ({
  riveValues: looks.map((mascot) => ({ mascot, values: mascotRiveValues(mascot) })),
  framing: {
    figure: viewBox(FIGURE_VIEW_BOX),
    portrait: viewBox(portraitViewBox("none")),
    portraitWithHat: viewBox(portraitViewBox("beanie"))
  }
})

const viewBox = (box) => box.split(" ").map(Number)

const outputPath = (name) => (name.startsWith("/") ? name : join(bundled, name))

const write = (files) => {
  for (const [name, bytes] of Object.entries(files)) {
    mkdirSync(dirname(outputPath(name)), { recursive: true })
    writeFileSync(outputPath(name), bytes)
  }
}

const stale = (files) =>
  Object.entries(files).filter(([name, bytes]) => {
    try {
      return !readFileSync(outputPath(name)).equals(bytes)
    } catch {
      return true
    }
  })

const files = art()
if (process.argv.includes("--check")) {
  const outdated = stale(files)
  if (outdated.length > 0) {
    console.error(
      `The apps' bundled mascot art is stale (${outdated.map(([name]) => name).join(", ")}). ` +
        "Run `bun run mascots:export-art`."
    )
    process.exitCode = 1
  }
} else {
  write(files)
}

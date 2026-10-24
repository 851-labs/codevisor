#!/usr/bin/env node
import { mkdir } from "node:fs/promises"
import { createRequire } from "node:module"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

const sharp = createRequire(new URL("../../server/package.json", import.meta.url))("sharp")

const RENDERS = {
  "chrome-extension": [920, 592],
  "computer-use": [920, 602],
  "ghostty-terminal": [1240, 460],
  "inspector-context": [560, 833],
  "inspector-machine": [560, 716],
  "inspector-usage": { light: [560, 562], dark: [560, 563] },
  "linux-install": { dark: [1616, 1032] },
  notifications: { light: [880, 349], dark: [880, 348] },
  "settings-accounts-window": [1784, 1448],
  "settings-mcps-window": [1784, 1448],
  "settings-sounds-window": [1784, 1448],
  "settings-updates-window": [1784, 1448],
  "simulator-pane": [2116, 1504],
  "usage-limit": [760, 184],
  "worktree-picker": [690, 364]
}

const source = process.argv[2] ?? "/tmp/bento-shots"
const destination = fileURLToPath(new URL("../public/bento/", import.meta.url))

await mkdir(destination, { recursive: true })

const mismatches = []
for (const [name, size] of Object.entries(RENDERS)) {
  for (const scheme of Array.isArray(size) ? ["light", "dark"] : Object.keys(size)) {
    const [width, height] = Array.isArray(size) ? size : size[scheme]
    const input = join(source, `${name}-${scheme}@2x.png`)
    const output = join(destination, `${name}-${scheme}.webp`)
    const image = sharp(input)
    const metadata = await image.metadata()
    if (metadata.width !== width || metadata.height !== height) {
      mismatches.push(
        `${name}-${scheme}: ${metadata.width}×${metadata.height}, expected ${width}×${height}`
      )
    }
    const info = await image.webp({ lossless: true, effort: 6 }).toFile(output)
    console.log(
      `${name}-${scheme}.webp  ${info.width}×${info.height}  ${Math.round(info.size / 1024)} KB`
    )
  }
}

if (mismatches.length > 0) {
  console.error("\nThese renders changed size; update their width and height on the homepage:")
  for (const line of mismatches) console.error(`  ${line}`)
  process.exitCode = 1
}

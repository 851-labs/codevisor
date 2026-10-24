#!/usr/bin/env node
import { copyFile, mkdir } from "node:fs/promises"
import { createRequire } from "node:module"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

const sharp = createRequire(new URL("../../server/package.json", import.meta.url))("sharp")

const SCREENSHOTS = {
  "mac-conversation-desktop": [3024, 1964],
  "ipad-conversation": [2420, 1668],
  "iphone-conversation": [1206, 2622],
  "iphone-projects": [1206, 2622]
}

const source = process.argv[2] ?? "/tmp/app-screenshots/landing"
const destination = fileURLToPath(new URL("../public/screenshots/", import.meta.url))

await mkdir(destination, { recursive: true })

const mismatches = []
for (const [name, [width, height]] of Object.entries(SCREENSHOTS)) {
  for (const file of [`${name}.webp`, `${name}-dark.webp`]) {
    const input = join(source, file)
    const metadata = await sharp(input).metadata()
    if (metadata.format !== "webp" || metadata.width !== width || metadata.height !== height) {
      mismatches.push(
        `${file}: ${metadata.format} ${metadata.width}×${metadata.height}, expected webp ${width}×${height}`
      )
      continue
    }
    await copyFile(input, join(destination, file))
    console.log(`${file}  ${width}×${height}`)
  }
}

if (mismatches.length > 0) {
  console.error("\nSkipped screenshots that don't match the sizes the homepage lays out for:")
  for (const line of mismatches) console.error(`  ${line}`)
  process.exitCode = 1
}

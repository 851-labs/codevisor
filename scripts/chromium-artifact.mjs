import { resolve } from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"

import { ensureChromium } from "../packages/devtools/src/chromium-artifact.ts"

const architectures = process.argv.slice(2)
await ensureChromium(
  resolve(fileURLToPath(new URL("..", import.meta.url))),
  process.env,
  architectures.length > 0 ? architectures : undefined
)

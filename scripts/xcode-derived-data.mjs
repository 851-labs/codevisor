import { realpath } from "node:fs/promises"
import process from "node:process"
import { fileURLToPath } from "node:url"

import { ensureXcodeDerivedDataSettings } from "../packages/devtools/src/xcode-derived-data.ts"

await ensureXcodeDerivedDataSettings(
  process.argv[2] ?? (await realpath(fileURLToPath(new URL("..", import.meta.url))))
)

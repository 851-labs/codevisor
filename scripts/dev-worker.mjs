import { realpath } from "node:fs/promises"
import process from "node:process"
import { fileURLToPath } from "node:url"

import { runDevelopmentWorker } from "../packages/devtools/src/dev-worker.ts"
import { processIdentity } from "../packages/processes/src/index.mjs"

await runDevelopmentWorker(
  await realpath(fileURLToPath(new URL("..", import.meta.url))),
  process.argv.slice(2),
  processIdentity
)
